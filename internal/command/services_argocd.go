package command

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// servicesArgocdToggle runs enable/disable for postgres or mysql when Argo CD
// holds the devzone charts. It mirrors services_argocd_toggle in the former
// argocd-services-svc.sh: the [services] section is written, then reconciled,
// and --yes on disable removes the namespace and data mirrors.
func servicesArgocdToggle(ctx *cli.Context, service, action string, args []string) int {
	root := workspaceRoot()
	conf := argocd.Conf{Path: filepath.Join(root, ".argocd.conf")}
	switch action {
	case "enable":
		if len(args) != 0 {
			fmt.Fprintf(ctx.Err, "✖ %s through Argo CD takes no option (got: %s)\n", service, strings.Join(args, " "))
			return 1
		}
		if code := runWorkstationArgoCD(ctx, "chart-require", service); code != 0 {
			return code
		}
		revision, err := argocd.ResolveRevision(context.Background(), argocd.RevisionInputs{
			Runner:   fexec.ExecRunner{},
			Root:     root,
			CodeRoot: filepath.Join(workspace.PackageRoot(), ".devcontainer"),
			ConfPath: conf.Path,
			Repo:     os.Getenv("DEVZONE_REPO_URL"),
			Chart:    "devzone",
		})
		if err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		fmt.Fprintf(ctx.Out, "▶ %s as an Argo CD Application (charts/devzone-%s at %s)…\n", service, service, revision)
		if err := servicesNote(conf, service, "on"); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		if code := runWorkstationArgoCD(ctx, "services-reconcile"); code != 0 {
			return code
		}
		fmt.Fprintf(ctx.Out, "✔ Application devzone-%s declared ([services] %s = on in %s); status: devzone workspace argocd status; local access: devzone workspace ports\n", service, service, conf.Path)
		return 0
	case "disable":
		yes, code := yesFlag(ctx.Err, "services disable "+service+" [--yes]", args)
		if code != 0 {
			return code
		}
		if err := servicesNote(conf, service, "off"); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		if code := runWorkstationArgoCD(ctx, "services-reconcile"); code != 0 {
			return code
		}
		if yes {
			r := workspace.ExecRunner{}
			flag := contextFlag(r)
			_, _ = r.Kubectl(append(flag, "delete", "namespace", "devzone-"+service, "--wait=true", "--ignore-not-found"), nil, io.Discard, io.Discard)
			if service == "postgres" {
				_ = os.RemoveAll(filepath.Join(root, "workspace", ".postgres"))
			}
			fmt.Fprintf(ctx.Out, "✔ %s removed: Application, namespace devzone-%s and data ([services] %s = off)\n", service, service, service)
			return 0
		}
		fmt.Fprintf(ctx.Out, "✔ %s stopped: Application removed, the namespace devzone-%s, the volumes and the data stay (devzone workspace services disable %s --yes to remove the data)\n", service, service, service)
		return 0
	default:
		return 1
	}
}

// servicesNote writes svc=state in the [services] section of .argocd.conf,
// keeping other service entries.
func servicesNote(conf argocd.Conf, service, state string) error {
	entries := conf.Entries()
	var pairs []string
	for _, e := range entries {
		if e.Section != "services" || e.Key == service {
			continue
		}
		pairs = append(pairs, e.Key+"="+e.Value)
	}
	pairs = append(pairs, service+"="+state)
	return conf.Set("services", pairs...)
}

// yesFlag parses the only accepted option for a removal: --yes.
func yesFlag(errOut io.Writer, usage string, args []string) (bool, int) {
	found := false
	for _, arg := range args {
		if arg == "--yes" {
			found = true
			continue
		}
		fmt.Fprintf(errOut, "✖ unknown option: %s (devzone workspace %s)\n", arg, usage)
		return false, 1
	}
	return found, 0
}

// workspaceRoot returns the devzone folder of the workstation.
func workspaceRoot() string {
	if root := os.Getenv("DEVZONE_ROOT"); root != "" {
		return root
	}
	root, err := os.Getwd()
	if err != nil {
		return "."
	}
	return root
}

// contextFlag returns the kubectl context flag for the devzone context.
func contextFlag(r workspace.Runner) []string {
	var out strings.Builder
	status, _ := r.Kubectl([]string{"config", "get-contexts", "-o", "name"}, nil, &out, io.Discard)
	if status != 0 {
		return nil
	}
	for _, line := range strings.Split(out.String(), "\n") {
		if line == "devzone" {
			return []string{"--context", "devzone"}
		}
	}
	return nil
}
