package command

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"
)

// workspaceDeploy runs the cluster part of "devzone workspace start" for the
// launcher: with Argo CD active it declares the Application through the shared
// rule, otherwise it keeps the direct chart installation. It is called by the
// shell entry point only when the Go program is present.
func workspaceDeploy(ctx *cli.Context) int {
	if len(ctx.Args) != 4 {
		fmt.Fprintln(ctx.Err, "devzone workspace deploy <repository> <tag> <with-image>")
		return 2
	}
	repo, tag, withImage := ctx.Args[1], ctx.Args[2], ctx.Args[3] == "yes"
	root := os.Getenv("DEVZONE_ROOT")
	if root == "" {
		dir, err := os.Getwd()
		if err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		root = dir
	}
	state := os.Getenv("DEVZONE_STATE")
	if state == "" {
		state = filepath.Join(root, ".devzone.modules")
	}
	if !argoCDHoldsWorkspace(ctx.Runner, state) {
		return 3
	}
	return workspaceDeployArgo(ctx, root, repo, tag, withImage)
}

// argoCDHoldsWorkspace reports whether Argo CD is wanted and installed: this
// is the same rule as the shell argocd_active, read without touching a chart.
func argoCDHoldsWorkspace(runner fexec.Runner, state string) bool {
	if stateLine(state, "argocd") == "off" {
		return false
	}
	res, err := runner.Run(context.Background(), "kubectl",
		[]string{"--context", "devzone", "get", "namespace", "devzone-argocd"}, fexec.Opts{})
	return err == nil && res.Code == 0
}

// workspaceDeployArgo declares the workspace Application. An existing helm
// release is adopted as it is: no release secret, volume or namespace is
// deleted, and a missing revision stops the start before any change.
func workspaceDeployArgo(ctx *cli.Context, root, repo, tag string, withImage bool) int {
	if code := workspaceChartRequire(root); code != 0 {
		fmt.Fprintln(ctx.Err, "devzone : workspace : chart charts/devzone-workspace missing or misnamed")
		return code
	}
	revision, err := rule.ResolveRevision(context.Background(), rule.RevisionInputs{
		Runner: ctx.Runner, Root: root, CodeRoot: filepath.Join(root, ".devcontainer"),
		ConfPath: filepath.Join(root, ".argocd.conf"), Repo: os.Getenv("DEVZONE_REPO_URL"),
		Chart: "devzone-workspace",
	})
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		fmt.Fprintln(ctx.Err, "nothing was installed: set DEVZONE_ARGOCD_REVISION=<tag or branch> (devzone workspace argocd init)")
		return 1
	}
	chartRepo := os.Getenv("DEVZONE_REPO_URL")
	if chartRepo == "" {
		chartRepo = "https://github.com/SimBienvenueHoulBoumi/devzone.git"
	}
	params := []string{"image.tag=" + tag}
	if withImage {
		params = append(params, "image.repository="+repo)
	}
	if tag == "latest" {
		params = append(params, "image.pullPolicy=Always")
	}
	params = append(params, egressParams(statePath(root))...)
	fmt.Fprintf(ctx.Out, "▶ Application devzone-workspace (Argo CD, charts/devzone-workspace at %s)…\n", revision)
	return workspaceApplyApplication(ctx, root, chartRepo, revision, params)
}

// statePath returns the state file of the devzone folder of the workstation.
func statePath(root string) string {
	if path := os.Getenv("DEVZONE_STATE"); path != "" {
		return path
	}
	return filepath.Join(root, ".devzone.modules")
}

// stateLine returns the last value of key in the state file, as state_read
// did in the shell entry point. A missing file gives an empty string.
func stateLine(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	value := ""
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, prefix) {
			value = strings.TrimPrefix(line, prefix)
		}
	}
	return value
}

// egressParams turns the egress settings of the state into Helm parameters,
// as egress_params of workspace-egress.sh did, without running shell.
func egressParams(state string) []string {
	mode := stateLine(state, "egress")
	if mode != "observation" && mode != "strict" {
		return nil
	}
	params := []string{"egressProxy.enabled=true", "egressProxy.mode=" + mode}
	if domains := stateLine(state, "egress_domains"); domains != "" {
		params = append(params, "egressProxy.extraDomains="+domains)
	}
	return params
}
