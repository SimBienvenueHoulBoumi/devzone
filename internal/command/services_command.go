package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// commandServices runs every "workspace services" form in Go: Argo CD itself
// through the shared Argo CD library, the services held by its Applications
// through the same library, and the other forms through the pod administrator.
// The token is read from the environment only by tests, which never reach a
// real cluster.
func commandServices(args []string, out, errOut io.Writer) int {
	service := ""
	if len(args) > 2 {
		service = args[2]
	}
	if service == "argocd" && len(args) > 1 {
		ctx := &cli.Context{Args: args, Out: out, Err: errOut}
		return servicesArgoCD(ctx, args[1])
	}
	held := service == "postgres" || service == "mysql"
	if held && workspace.ArgoCDHoldsCharts(workspace.ExecRunner{}, modulesFile()) {
		return delegate(append([]string{"workspace"}, args...), out, errOut)
	}
	env := workspace.ServicesEnv{
		Runner:  workspace.ExecRunner{},
		Modules: modulesFile(),
		Out:     out,
		ErrOut:  errOut,
	}
	return env.Run(args[1:])
}

// modulesFile is the state file of the workstation devzone folder, as in the
// shell scripts sourced by manage/workspace.sh.
func modulesFile() string {
	return ".devzone.modules"
}
