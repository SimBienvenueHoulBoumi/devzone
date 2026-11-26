package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/relays"
)

// portHelp is the usage text of the port command, in the command's own help.
const portHelp = "List or remove a workstation port relay:\n" +
	"  devzone port [list]           relays: port, active, application\n" +
	"  devzone port list --json      relays as a JSON array\n" +
	"  devzone port close <n>        remove the relay and its port from the state\n" +
	"  devzone port resume           one-line recap of the relays\n"

// newPortEnvironment is a variable so tests can inject a fake runner and probe.
var newPortEnvironment = portEnvironment

// portEnvironment resolves the state file and the instance of a port command.
func portEnvironment(ctx *cli.Context) *relays.Env {
	stateFile := os.Getenv("DEVZONE_STATE")
	if stateFile == "" {
		root := devzoneRoot()
		if root == "" {
			return nil
		}
		stateFile = filepath.Join(root, ".devzone.modules")
	}
	return relays.New(stateFile, relays.Instance(), ctx.Out, ctx.Err)
}

// runPort lists or closes the workstation relays, with the state written by
// the shared state package and the relay pod handled through kubectl.
func runPort(ctx *cli.Context) int {
	env := newPortEnvironment(ctx)
	if env == nil {
		fmt.Fprintln(ctx.Err, "devzone port: devzone folder unavailable")
		return 1
	}
	args := ctx.Args
	if len(args) == 0 {
		_ = env.List()
		return 0
	}
	switch args[0] {
	case "list":
		if len(args) == 2 && args[1] == "--json" {
			_ = env.JSON()
		} else {
			_ = env.List()
		}
		return 0
	case "close", "--close":
		if len(args) < 2 {
			fmt.Fprintln(ctx.Err, "devzone : port : invalid port : (none) (1-65535)")
			return 1
		}
		n, err := strconv.Atoi(args[1])
		if err != nil || !relays.ValidPort(n) || strconv.Itoa(n) != args[1] {
			fmt.Fprintf(ctx.Err, "devzone : port : invalid port : %s (1-65535)\n", args[1])
			return 1
		}
		if err := env.Close(n); err != nil {
			fmt.Fprintf(ctx.Err, "devzone : port : state not saved : %s\n", env.State)
			return 1
		}
		return 0
	case "resume":
		_ = env.Summary()
		return 0
	case "-h", "--help":
		fmt.Fprint(ctx.Out, portHelp)
		return 0
	}
	return 0
}
