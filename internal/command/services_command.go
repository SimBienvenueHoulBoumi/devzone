package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// commandServices runs the non-Argo CD forms of "workspace services" in Go,
// and delegates Argo CD itself and the services held by its Applications,
// which need the GitOps libraries of the workstation. The token of the
// temporary administrator is read from the environment only by tests, which
// never reach a real cluster.
func commandServices(args []string, out, errOut io.Writer) int {
	service := ""
	if len(args) > 2 {
		service = args[2]
	}
	held := service == "postgres" || service == "mysql"
	if service == "argocd" || (held && workspace.ArgoCDHoldsCharts(workspace.ExecRunner{}, modulesFile())) {
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
