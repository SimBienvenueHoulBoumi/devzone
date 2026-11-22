package podcmd

import (
	"fmt"
	"io"
	"os"
)

// printVersion prints "devzone <version>": the version is DEVZONE_VERSION, "unknown" when it is unset or empty, as the pod shell does; extra arguments are ignored.
func printVersion(args []string, out, errOut io.Writer) int {
	version := os.Getenv("DEVZONE_VERSION")
	if version == "" {
		version = "unknown"
	}
	fmt.Fprintf(out, "devzone %s\n", version)
	return 0
}
