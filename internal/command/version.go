package command

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
)

// unknownVersion is printed when no package.json can be read, as manage/devzone does
const unknownVersion = "inconnue"

// printVersion writes the version of the package alone, on one line, as
// "bash manage/devzone --version" does. Exit status 0.
func printVersion(out io.Writer) int {
	fmt.Fprintln(out, packageVersion(versionFolders()))
	return 0
}

// versionFolders lists, in search order, the folders that may hold the
// package.json of the package: the folder of the binary, its parent, then the
// package root of the bash entry point (manage/devzone sits one level below the
// root). Symbolic links are resolved, as the bash entry point does with readlink.
func versionFolders() []string {
	var folders []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(resolve(exe))
		folders = append(folders, dir, filepath.Dir(dir))
	}
	if script, err := bashbridge.Script(os.Getenv(bashbridge.EnvVar)); err == nil {
		folders = append(folders, filepath.Dir(filepath.Dir(resolve(script))))
	}
	return folders
}

// resolve returns path with its symbolic links resolved, or path itself when
// that is not possible
func resolve(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// packageVersion returns the version held by the first folder that has a
// package.json: the first file found decides, as bash reads one file only.
// Without any file, it returns unknownVersion.
func packageVersion(folders []string) string {
	for _, dir := range folders {
		data, err := os.ReadFile(filepath.Join(dir, "package.json"))
		if err == nil {
			return versionOf(data)
		}
	}
	return unknownVersion
}

// versionOf reads the version field of a package.json. The values follow what
// "node -p" prints in the bash entry point: a string as it is, undefined when
// the field is missing, the JSON text for another value. Invalid JSON gives
// unknownVersion, as the failing node command does there.
func versionOf(data []byte) string {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return unknownVersion
	}
	raw, ok := fields["version"]
	if !ok {
		return "undefined"
	}
	var version string
	// A JSON null unmarshals into an empty string without error: it is checked apart
	if err := json.Unmarshal(raw, &version); err == nil && string(raw) != "null" {
		return version
	}
	return string(raw)
}
