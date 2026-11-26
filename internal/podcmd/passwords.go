package podcmd

import (
	"fmt"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/passwords"
)

// runPasswords regenerates the grouped credentials from the module files. The
// bare command prints only their path, never their content or a secret.
func runPasswords(ctx *cli.Context) int {
	root := devzoneRoot()
	if root == "" {
		fmt.Fprintln(ctx.Err, "devzone passwords: devzone folder unavailable")
		return 1
	}
	switch {
	case len(ctx.Args) == 0:
		if err := passwords.Regenerate(root); err != nil {
			fmt.Fprintln(ctx.Err, "devzone : grouped credentials not updated")
		}
		fmt.Fprintln(ctx.Out, passwords.Path(root))
		return 0
	case len(ctx.Args) == 1 && ctx.Args[0] == "regenerate":
		if err := passwords.Regenerate(root); err != nil {
			fmt.Fprintln(ctx.Err, "devzone : grouped credentials not updated")
			return 1
		}
		return 0
	case len(ctx.Args) == 1 && ctx.Args[0] == "path":
		fmt.Fprintln(ctx.Out, passwords.Path(root))
		return 0
	default:
		fmt.Fprintln(ctx.Err, "devzone : passwords : regenerate | path")
		return 1
	}
}
