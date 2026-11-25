package podcmd

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// printVersion prints "devzone <version>": the version is DEVZONE_VERSION, "unknown" when it is unset or empty, as the pod shell does; extra arguments are ignored.
func printVersion(ctx *cli.Context) int {
	out := ctx.Out
	_ = ctx.Args
	version := os.Getenv("DEVZONE_VERSION")
	if version == "" {
		version = "unknown"
	}
	fmt.Fprintf(out, "devzone %s\n", version)
	return 0
}
