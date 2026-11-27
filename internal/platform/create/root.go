package create

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// UnknownVersion is printed when no package.json can be read, as manage/devzone does.
const UnknownVersion = "inconnue"

// PackageRoot returns the package folder to copy from: DEVZONE_PAQUET when the
// caller sets it, the package root of the bash entry point
// (DEVZONE_BASH_ENTRY), else the folder holding package.json above the
// executable, else the working directory.
func PackageRoot() string {
	if p := os.Getenv("DEVZONE_PAQUET"); p != "" {
		return p
	}
	if entry := os.Getenv("DEVZONE_BASH_ENTRY"); entry != "" {
		if script, err := filepath.Abs(entry); err == nil {
			if resolved, err := filepath.EvalSymlinks(script); err == nil {
				script = resolved
			}
			return filepath.Dir(filepath.Dir(script))
		}
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			dir = resolved
		}
		for {
			if hasPackageJSON(dir) {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return "."
}

// hasPackageJSON tells whether dir holds a package.json file.
func hasPackageJSON(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "package.json"))
	return err == nil && !info.IsDir()
}

// PackageVersion returns the version field of package.json in root, or
// UnknownVersion when it cannot be read, as version() does.
func PackageVersion(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil {
		return UnknownVersion
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return UnknownVersion
	}
	raw, ok := fields["version"]
	if !ok {
		return "undefined"
	}
	var version string
	if err := json.Unmarshal(raw, &version); err == nil && string(raw) != "null" {
		return version
	}
	return string(raw)
}
