package manifest

import (
	"os"
	"path/filepath"
	"strings"
)

// PathAllowed tells whether a path read from a manifest may be touched. Why: a
// manifest can be edited by hand or be poisoned, so only a relative, simple path
// under a folder the package manages (or a file at its root) is accepted; ".."
// and "." segments, double slashes, newlines and tabs are refused.
func PathAllowed(rel string) bool {
	if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "//") || strings.ContainsAny(rel, "\n\t") {
		return false
	}
	padded := "/" + rel + "/"
	if strings.Contains(padded, "/../") || strings.Contains(padded, "/./") {
		return false
	}
	for _, prefix := range []string{".devcontainer/", "manage/", "core/", "scripts/"} {
		if strings.HasPrefix(rel, prefix) {
			return true
		}
	}
	switch rel {
	case "Makefile", "README.md", "LICENSE", ".gitattributes":
		return true
	}
	return false
}

// InsideFolder is a second defence after PathAllowed: the real parent folder of
// rel must stay under the real folder (symbolic links resolved). Why: a link
// inside the devzone that points outside of it must never lead an update to
// write or remove a file out of the folder.
func InsideFolder(folder, rel string) bool {
	root, err := realPath(folder)
	if err != nil {
		return false
	}
	parent, err := realPath(filepath.Join(folder, filepath.Dir(filepath.FromSlash(rel))))
	if err != nil {
		return false
	}
	return parent == root || strings.HasPrefix(parent, root+string(filepath.Separator))
}

// realPath returns the absolute path of p with every symbolic link resolved, as
// pwd -P gives it.
func realPath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

// IsProtected tells whether an update must never touch rel, even when an old
// manifest lists it. Why: the workspace, the state, the logins, the log and the
// git history belong to the user: a devzone update replaces the package and
// nothing else.
func IsProtected(rel string) bool {
	switch rel {
	case "workspace", ".devzone.version", ".devzone.modules", ".devzone.packages",
		".password", ".app", ".devzone.log", ".git":
		return true
	}
	for _, prefix := range []string{"workspace/", ".devzone.modules-", ".git/"} {
		if strings.HasPrefix(rel, prefix) {
			return true
		}
	}
	return false
}

// OldTree tells whether folder holds the old layout named tree ("core" or
// "scripts") as a devzone made it, by its marker files. Why: a folder named
// scripts/ may be the user's own; it is only treated as devzone's when its two
// own files are there.
func OldTree(folder, tree string) bool {
	switch tree {
	case "core":
		return isFile(folder, "core/devzone") || isFile(folder, "core/scripts/uninstall.sh")
	case "scripts":
		return isFile(folder, "scripts/uninstall.sh") && isFile(folder, "scripts/launch.sh")
	}
	return false
}

// KnownOldFile tells whether rel, a file of an old layout, is one the package
// once delivered: the names moved from manage/scripts/ into core/scripts/ or
// scripts/, core/devzone, and all of core/test/ and core/docs/. Why: any other
// file in an old tree belongs to the user and is kept. root is the package.
func KnownOldFile(root, rel string) bool {
	var name string
	switch {
	case rel == "core/devzone", strings.HasPrefix(rel, "core/test/"), strings.HasPrefix(rel, "core/docs/"):
		return true
	case strings.HasPrefix(rel, "core/scripts/"):
		name = strings.TrimPrefix(rel, "core/scripts/")
	case strings.HasPrefix(rel, "scripts/"):
		name = strings.TrimPrefix(rel, "scripts/")
	default:
		return false
	}
	return isFile(root, "manage/scripts/"+name)
}

// isFile reports whether folder/rel is a regular file, following links as the
// shell test -f does.
func isFile(folder, rel string) bool {
	info, err := os.Stat(filepath.Join(folder, filepath.FromSlash(rel)))
	return err == nil && info.Mode().IsRegular()
}
