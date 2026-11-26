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

// workstationArgoCDRun is injectable so a routing test can check the commands
// sent to the GitOps library without a cluster, a token or a network call.
var workstationArgoCDRun = func(ctx context.Context, args []string, out, errOut io.Writer, opts argocd.Options) int {
	return argocd.Run(ctx, args, out, errOut, opts)
}

// argocdOptions resolves the folders and the collaborators of the Argo CD
// library for a command issued from a workstation devzone folder.
func argocdOptions(ctx *cli.Context) argocd.Options {
	root := os.Getenv("DEVZONE_ROOT")
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			root = "."
		}
	}
	return argocd.Options{
		Runner: fexec.ExecRunner{}, Out: ctx.Out, Err: ctx.Err,
		Root:       root,
		CodeRoot:   filepath.Join(workspace.PackageRoot(), ".devcontainer"),
		StatePath:  filepath.Join(root, ".devzone.modules"),
		KubeHost:   os.Getenv("DEVZONE_KUBE_HOST"),
		KubeConfig: os.Getenv("DEVZONE_KUBE_CONFIG"),
	}
}

// runWorkstationArgoCD sends one command of the workstation to the Argo CD
// library, with the folders of the devzone the user is standing in.
func runWorkstationArgoCD(ctx *cli.Context, args ...string) int {
	return workstationArgoCDRun(context.Background(), args, ctx.Out, ctx.Err, argocdOptions(ctx))
}

// noteStateKey writes one key=value line of .devzone.modules, keeping the
// other lines. The shell state_note wrote the line at the end of the file.
func noteStateKey(root, key, value string) error {
	path := filepath.Join(root, ".devzone.modules")
	data, err := os.ReadFile(path)
	if err != nil {
		data = nil
	}
	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		if line != "" && !strings.HasPrefix(line, key+"=") {
			lines = append(lines, line)
		}
	}
	lines = append(lines, fmt.Sprintf("%s=%s", key, value))
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
}

// servicesArgoCD runs the install or uninstall of the Argo CD module from the
// workstation and remembers the choice in the modules file on success only.
func servicesArgoCD(ctx *cli.Context, action string) int {
	command := "install"
	value := "on"
	if action == "disable" {
		command, value = "uninstall", "off"
	}
	if code := runWorkstationArgoCD(ctx, command); code != 0 {
		return code
	}
	root := os.Getenv("DEVZONE_ROOT")
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			return 1
		}
	}
	if err := noteStateKey(root, "argocd", value); err != nil {
		fmt.Fprintf(ctx.Err, "✖ cannot write .devzone.modules: %v\n", err)
		return 1
	}
	return 0
}
