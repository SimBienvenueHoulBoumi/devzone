package argocd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// defaultRepo is the public repository that carries the devzone charts. It is
// used when neither DEVZONE_REPO_URL nor the caller says otherwise.
const defaultRepo = "https://github.com/SimBienvenueHoulBoumi/devzone.git"

// packageVersion reads the first "version": "..." field of a package.json,
// as the shell sed did. Reading it by hand keeps this package small enough for
// the launcher binary.
func packageVersion(data []byte) string {
	text := string(data)
	i := strings.Index(text, `"version"`)
	if i < 0 {
		return ""
	}
	rest := text[i+len(`"version"`):]
	colon := strings.IndexByte(rest, ':')
	if colon < 0 {
		return ""
	}
	rest = rest[colon+1:]
	start := strings.IndexByte(rest, '"')
	if start < 0 {
		return ""
	}
	rest = rest[start+1:]
	end := strings.IndexByte(rest, '"')
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// stableTagParts returns the three numbers of a vX.Y.Z tag, and whether the
// ref is a stable published version. Previews and other tags are ignored.
func stableTagParts(ref string) (int64, int64, int64, bool) {
	if !strings.HasPrefix(ref, "v") {
		return 0, 0, 0, false
	}
	parts := strings.Split(ref[1:], ".")
	if len(parts) != 3 {
		return 0, 0, 0, false
	}
	numbers := [3]int64{}
	for i, part := range parts {
		if part == "" {
			return 0, 0, 0, false
		}
		for _, c := range part {
			if c < '0' || c > '9' {
				return 0, 0, 0, false
			}
		}
		n, err := strconv.ParseInt(part, 10, 64)
		if err != nil {
			return 0, 0, 0, false
		}
		numbers[i] = n
	}
	return numbers[0], numbers[1], numbers[2], true
}

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
	if v := confRevision(confPath); v != "" {
		return v, nil
	}
	if v := packageRevision(in.Root, in.CodeRoot); v != "" {
		return v, nil
	}
	return latestChartRevision(ctx, in)
}

// confRevision returns the revision kept in [argocd] of .argocd.conf, or an
// empty string. Only that one setting is read, without the rest of the conf
// machinery, so that the launcher does not have to link the domain packages.
func confRevision(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		if section != "argocd" || !strings.HasPrefix(line, "revision") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(key) == "revision" {
			return strings.TrimSpace(value)
		}
	}
	return ""
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
	version := packageVersion(data)
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
		maj, min, pat, stable := stableTagParts(ref)
		if !stable {
			continue
		}
		seen[ref] = true
		tags = append(tags, tagged{name: ref, maj: maj, min: min, pat: pat})
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
