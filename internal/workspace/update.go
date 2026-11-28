package workspace

import (
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// imageRepository is the GitHub repository whose vX.Y.Z tags are the stable
// releases, as DEVZONE_REPO_URL in argocd-workspace.sh.
const imageRepository = "https://github.com/SimBienvenueHoulBoumi/devzone.git"

// stableVersion tells whether a tag is a stable release tag vX.Y.Z.
func stableVersion(tag string) bool {
	if !strings.HasPrefix(tag, "v") {
		return false
	}
	parts := strings.Split(tag[1:], ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" || strings.Trim(part, "0123456789") != "" {
			return false
		}
	}
	return true
}

// LatestVersion returns the highest stable release of tags, without the v, as
// "git ls-remote --tags --refs | sort -V | tail -1" does in update_latest_version.
func LatestVersion(tags []string) string {
	var versions []string
	for _, tag := range tags {
		if stableVersion(tag) {
			versions = append(versions, tag[1:])
		}
	}
	if len(versions) == 0 {
		return ""
	}
	sort.Slice(versions, func(i, j int) bool {
		a, b := strings.Split(versions[i], "."), strings.Split(versions[j], ".")
		for k := range a {
			x, _ := strconv.Atoi(a[k])
			y, _ := strconv.Atoi(b[k])
			if x != y {
				return x < y
			}
		}
		return false
	})
	return versions[len(versions)-1]
}

// GitTags lists the tags of a repository with git ls-remote, as
// update_latest_version does. A failing call gives no tag.
func GitTags(repository string) []string {
	out, err := exec.Command("git", "ls-remote", "--tags", "--refs", repository).Output()
	if err != nil {
		return nil
	}
	var tags []string
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && strings.HasPrefix(fields[1], "refs/tags/") {
			tags = append(tags, strings.TrimPrefix(fields[1], "refs/tags/"))
		}
	}
	return tags
}

// applicationCurrent returns the revision and image tag of the workspace
// Application, or two empty strings with helm direct (update_current).
func applicationCurrent(r Runner) (string, string) {
	flag := contextFlag(r)
	text := kubectlText(r, append(flag, "-n", config.NamespaceArgoCD, "get", "application.argoproj.io",
		"devzone-workspace", "-o", `jsonpath={.spec.source.targetRevision} {.spec.source.helm.parameters[?(@.name=="image.tag")].value}`))
	fields := strings.Fields(text)
	if len(fields) < 2 {
		return "", ""
	}
	return fields[0], fields[1]
}

// upToDate tells whether the Application already points at the release.
func upToDate(r Runner, version string) bool {
	revision, tag := applicationCurrent(r)
	return revision == "v"+version && tag == version
}

// usageUpdate is the message of a wrong option.
const usageUpdate = "devzone workspace update [--version X.Y.Z] [--yes]"

// parseUpdateOptions reads --version and --yes, as update_workspace does.
func parseUpdateOptions(args []string) (version string, yes bool, errOut string, ok bool) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--version":
			if i+1 >= len(args) || args[i+1] == "" {
				return "", false, fmt.Sprintf("✖ option --version: give X.Y.Z (%s)\n", usageUpdate), false
			}
			i++
			version = args[i]
		case "--yes":
			yes = true
		default:
			return "", false, fmt.Sprintf("✖ unknown option: %s (%s)\n", args[i], usageUpdate), false
		}
	}
	return version, yes, "", true
}

// validRelease tells whether an explicit version has the X.Y.Z shape.
func validRelease(version string) bool {
	if version == "" || strings.Trim(version, "0123456789.") != "" {
		return false
	}
	return len(strings.Split(version, ".")) == 3 && !strings.Contains(version, "..")
}
