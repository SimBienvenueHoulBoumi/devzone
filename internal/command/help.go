package command

import (
	"fmt"
	"io"
	"strings"
)

// printHelp writes the help text, as "bash manage/devzone --help" does, with the
// version of the package on its first line. Exit status 0.
func printHelp(out io.Writer) int {
	// The bash entry point gives the version through a command substitution:
	// its trailing newlines are removed
	version := strings.TrimRight(packageVersion(versionFolders()), "\n")
	fmt.Fprint(out, helpText(version))
	return 0
}

// helpText returns the help text with version in place of its placeholder
func helpText(version string) string {
	return strings.ReplaceAll(helpTemplate, "{version}", version)
}
