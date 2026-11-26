// Package gitenv holds the Git variables that select a repository and the
// helper that removes them before a command is aimed at a chosen folder.
package gitenv

import "strings"

// RepoVars are the Git variables that override the repository discovered from
// the working directory. A git hook exports them, so an inherited value makes
// "git -C folder" read and write the hook's repository instead of folder.
var RepoVars = []string{
	"GIT_DIR",
	"GIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_NAMESPACE",
	"GIT_PREFIX",
	"GIT_QUARANTINE_PATH",
}

// Clean returns env without the variables that select a repository. Settings
// such as GIT_CONFIG_GLOBAL and GIT_CONFIG_PARAMETERS are kept: they configure
// a git command instead of pointing it at another repository.
func Clean(env []string) []string {
	out := make([]string, 0, len(env))
	for _, entry := range env {
		name := entry
		if i := strings.IndexByte(entry, '='); i >= 0 {
			name = entry[:i]
		}
		if selects(name) {
			continue
		}
		out = append(out, entry)
	}
	return out
}

// selects reports whether name belongs to RepoVars.
func selects(name string) bool {
	for _, v := range RepoVars {
		if name == v {
			return true
		}
	}
	return false
}
