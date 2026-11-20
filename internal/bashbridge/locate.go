package bashbridge

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// EnvVar is the environment variable that sets the bash entry point explicitly.
const EnvVar = "DEVZONE_BASH_ENTRY"

// Script returns the path of the bash entry point to delegate to. rootEnv is
// the value of EnvVar (empty when unset): an explicit path wins and must be a
// file. Otherwise manage/devzone is searched in the folder of the binary, in its
// parent, then in the current folder (last resort, for a checkout). The binary
// sits in bin/ of the repository or of the npm package.
func Script(rootEnv string) (string, error) {
	exeDir := ""
	if exe, err := os.Executable(); err == nil {
		// Symlinks resolved: a link in PATH must point to the real binary folder
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		exeDir = filepath.Dir(exe)
	}
	wd, _ := os.Getwd()
	return find(rootEnv, exeDir, wd)
}

// find applies the search order of Script. The folders are parameters so that
// the order can be tested without the real binary and working folder.
func find(rootEnv, exeDir, wd string) (string, error) {
	if rootEnv != "" {
		if isFile(rootEnv) {
			return rootEnv, nil
		}
		return "", fmt.Errorf("bash entry point not found: DEVZONE_BASH_ENTRY names no file: %s", rootEnv)
	}
	var folders []string
	if exeDir != "" {
		folders = append(folders, exeDir, filepath.Dir(exeDir))
	}
	if wd != "" {
		folders = append(folders, wd)
	}
	for _, folder := range folders {
		candidate := filepath.Join(folder, "manage", "devzone")
		if isFile(candidate) {
			return candidate, nil
		}
	}
	return "", errors.New("bash entry point not found: set DEVZONE_BASH_ENTRY")
}

// isFile reports whether path is an existing regular file (links followed)
func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
