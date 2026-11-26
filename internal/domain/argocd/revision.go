package argocd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// defaultRepo is the public repository that carries the devzone charts. It is
// used when neither DEVZONE_REPO_URL nor the caller says otherwise.
const defaultRepo = "https://github.com/SimBienvenueHoulBoumi/devzone.git"

// packageVersionLine matches the version field of package.json, as the shell
// sed did. The name is distinct from the one of the legacy service hook.
var packageVersionLine = regexp.MustCompile(`"version"\s*:\s*"([^"]*)"`)

// stableTag matches a published version tag, without previews, as required by
// the revision rule: only vX.Y.Z tags of a release can hold a chart.
var stableTag = regexp.MustCompile(`^v([0-9]+)\.([0-9]+)\.([0-9]+)$`)

// RevisionInputs carries the inputs used to resolve the revision of the
// Applications. A Runner is injected so that no test reaches the network.
type RevisionInputs struct {
	Runner   fexec.Runner
	Root     string
	CodeRoot string
	ConfPath string
	Repo     string
	Chart    string
}

// ResolveRevision returns the revision of the devzone charts. It takes an
// explicit override first, then the kept setting, then the package version,
// then the most recent published tag that contains the chart. It never
// returns an empty revision: without one, the caller must fail instead of
// silently installing with helm.
func ResolveRevision(ctx context.Context, in RevisionInputs) (string, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if v := os.Getenv("DEVZONE_ARGOCD_REVISION"); v != "" {
		return v, nil
	}
	confPath := in.ConfPath
	if confPath == "" && in.Root != "" {
		confPath = filepath.Join(in.Root, ".argocd.conf")
	}
	if v := (Conf{Path: confPath}).Get("argocd", "revision"); v != "" {
		return v, nil
	}
	if v := packageRevision(in.Root, in.CodeRoot); v != "" {
		return v, nil
	}
	return latestChartRevision(ctx, in)
}

// packageRevision returns the v-tag of the package version, or an empty string
// for a development clone at 0.0.0 whose charts are not published in Git.
func packageRevision(root, codeRoot string) string {
	dir := root
	if dir == "" && codeRoot != "" {
		dir = filepath.Dir(codeRoot)
	}
	if dir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(dir, "package.json"))
	if err != nil {
		return ""
	}
	match := packageVersionLine.FindSubmatch(data)
	if len(match) < 2 {
		return ""
	}
	version := string(match[1])
	if version == "" || version == "0.0.0" {
		return ""
	}
	return "v" + version
}

// latestChartRevision finds the newest stable tag of the repository whose
// tree contains charts/<chart>. A failed tag listing is a hard error: no
// installation is attempted when the repository cannot be reached.
func latestChartRevision(ctx context.Context, in RevisionInputs) (string, error) {
	runner := in.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	repo := in.Repo
	if repo == "" {
		repo = os.Getenv("DEVZONE_REPO_URL")
	}
	if repo == "" {
		repo = defaultRepo
	}
	res, err := runner.Run(ctx, "git", []string{"ls-remote", "--tags", "--refs", repo}, fexec.Opts{})
	if err != nil {
		return "", fmt.Errorf("cannot list the tags of %s: %v; check the network or set DEVZONE_ARGOCD_REVISION=<tag> (devzone argocd init)", repo, err)
	}
	if res.Code != 0 {
		return "", fmt.Errorf("cannot list the tags of %s (git exit %d): %s; set DEVZONE_ARGOCD_REVISION=<tag> (devzone argocd init)", repo, res.Code, strings.TrimSpace(string(res.Stderr)))
	}
	tags := stableTags(string(res.Stdout))
	for _, tag := range tags {
		found, err := chartAt(ctx, runner, repo, in.Chart, tag)
		if err != nil {
			return "", err
		}
		if found {
			return tag, nil
		}
	}
	return "", fmt.Errorf("no published tag of %s contains charts/%s; set DEVZONE_ARGOCD_REVISION=<branch or tag containing the chart> (devzone argocd init)", repo, in.Chart)
}

// stableTags extracts the stable vX.Y.Z tags of a git ls-remote output, sorted
// from the newest version to the oldest, ignoring previews and duplicate refs.
func stableTags(out string) []string {
	type tagged struct {
		name string
		maj  int64
		min  int64
		pat  int64
	}
	var tags []tagged
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		ref := strings.TrimPrefix(fields[1], "refs/tags/")
		if ref == fields[1] || seen[ref] {
			continue
		}
		match := stableTag.FindStringSubmatch(ref)
		if match == nil {
			continue
		}
		parts := make([]int64, 3)
		for i := range parts {
			parts[i], _ = strconv.ParseInt(match[i+1], 10, 64)
		}
		seen[ref] = true
		tags = append(tags, tagged{name: ref, maj: parts[0], min: parts[1], pat: parts[2]})
	}
	sort.Slice(tags, func(i, j int) bool {
		a, b := tags[i], tags[j]
		if a.maj != b.maj {
			return a.maj > b.maj
		}
		if a.min != b.min {
			return a.min > b.min
		}
		return a.pat > b.pat
	})
	outTags := make([]string, 0, len(tags))
	for _, t := range tags {
		outTags = append(outTags, t.name)
	}
	return outTags
}

// chartAt reports whether the given tag contains charts/<chart> in the
// repository, through the GitHub contents API of the injected Runner. A
// network error is reported, while a missing chart simply tries another tag.
func chartAt(ctx context.Context, runner fexec.Runner, repo, chart, tag string) (bool, error) {
	slug := repoSlug(repo)
	if slug == "" {
		return false, fmt.Errorf("cannot check charts/%s at %s: unsupported repository URL %s; set DEVZONE_ARGOCD_REVISION=<tag>", chart, tag, repo)
	}
	path := "repos/" + slug + "/contents/charts/" + chart + "?ref=" + tag
	res, err := runner.Run(ctx, "gh", []string{"api", path, "--jq", ".type"}, fexec.Opts{})
	if err != nil {
		return false, fmt.Errorf("cannot read charts/%s at %s of %s: %v; check the network or set DEVZONE_ARGOCD_REVISION=<tag>", chart, tag, repo, err)
	}
	return res.Code == 0 && strings.TrimSpace(string(res.Stdout)) != "", nil
}

// repoSlug returns owner/name for a GitHub URL, or an empty string for another
// host: the contents API of gh only addresses GitHub repositories.
func repoSlug(repo string) string {
	slug := strings.TrimPrefix(repo, "https://github.com/")
	slug = strings.TrimPrefix(slug, "git@github.com:")
	slug = strings.TrimSuffix(slug, ".git")
	slug = strings.TrimSuffix(slug, "/")
	if strings.Count(slug, "/") != 1 {
		return ""
	}
	return slug
}
