package workspace

import (
	"fmt"
	"io"
	"strings"
)

// valuesExists reports whether a file is present in the GitHub GitOps
// repository. It is a variable so status tests can answer without a fake
// executable in PATH; only the blob sha is read, never the file content.
var valuesExists = func(repo, path string) bool {
	slug := strings.TrimSuffix(strings.TrimPrefix(repo, "https://github.com/"), ".git")
	if slug == "" || slug == repo || !strings.Contains(slug, "/") {
		return false
	}
	status, err := execCommand("gh", []string{"api", "repos/" + slug + "/contents/" + path, "--jq", ".sha"},
		nil, io.Discard, io.Discard)
	return err == nil && status == 0
}

// workspaceValuesLine reports the values file used by devzone-workspace and
// whether the GitOps repository already has it.
func workspaceValuesLine(repo, path string) string {
	if repo == "" || repo == "none" {
		return "  devzone-workspace values: not used (no GitOps repository)\n"
	}
	state := "absent"
	if valuesExists(repo, path) {
		state = "present"
	}
	return fmt.Sprintf("  devzone-workspace values: %s (%s)\n", path, state)
}
