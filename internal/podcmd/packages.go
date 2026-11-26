package podcmd

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/packages"
)

// packagesHelp is the usage text of the packages command.
const packagesHelp = "System packages kept after a rebuild (#351): a list in the devzone folder\n" +
	"(<root>/.devzone.packages, a comment header + one package name per line,\n" +
	"sorted, without duplicates), reinstalled at each container creation.\n" +
	"  devzone packages                  list with the state of each package\n" +
	"  devzone packages add <name>…      validates, installs, adds to the list\n" +
	"  devzone packages remove <name>…   removes from the list and uninstalls\n" +
	"  devzone packages apply            installs everything missing\n"

// newPackagesEnvironment is a variable so tests can inject a fake installer.
var newPackagesEnvironment = packagesEnvironment

// packageEnvOr returns key, or fallback when unset or empty.
func packageEnvOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// packagesEnvironment resolves the user's list and the injected installer.
func packagesEnvironment(ctx *cli.Context) *packages.Env {
	root := devzoneRoot()
	if root == "" {
		return nil
	}
	return &packages.Env{
		List:      filepath.Join(root, ".devzone.packages"),
		Marker:    packageEnvOr("DEVZONE_PACKAGES_MARKER", "/tmp/devzone-packages.failed"),
		Updated:   packageEnvOr("DEVZONE_PACKAGES_UPDATE", "/tmp/devzone-packages.updated"),
		Installer: packages.SystemFromEnvironment(fexec.ExecRunner{}),
		Out:       ctx.Out, Err: ctx.Err,
	}
}

// runPackages lists, adds, removes or applies the persistent system packages.
func runPackages(ctx *cli.Context) int {
	env := newPackagesEnvironment(ctx)
	if env == nil {
		fmt.Fprintln(ctx.Err, "devzone packages: devzone folder unavailable")
		return 1
	}
	args := ctx.Args
	var err error
	switch {
	case len(args) == 0 || args[0] == "list":
		err = env.Show()
	case args[0] == "add":
		err = env.Add(args[1:])
	case args[0] == "remove":
		err = env.Remove(args[1:])
	case args[0] == "apply":
		err = env.Apply()
	case args[0] == "-h" || args[0] == "--help":
		fmt.Fprint(ctx.Out, packagesHelp)
		return 0
	default:
		err = &packages.Refusal{Message: fmt.Sprintf("unknown command: %s (devzone packages --help)", args[0])}
	}
	if err != nil {
		var refusal *packages.Refusal
		if errors.As(err, &refusal) && refusal.Message != "" {
			fmt.Fprintf(ctx.Err, "devzone : packages : %s\n", refusal.Message)
		}
		return 1
	}
	return 0
}
