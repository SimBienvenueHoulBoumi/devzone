package command

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"
)

// workspaceChartRequire checks that the workspace chart is present and named
// devzone-workspace, as the pod command did, before an Application is declared.
func workspaceChartRequire(root string) int {
	data, err := os.ReadFile(filepath.Join(root, "charts", "devzone-workspace", "Chart.yaml"))
	if err != nil || !strings.Contains(string(data), "name: devzone-workspace\n") {
		return 2
	}
	return 0
}

// workspaceApplyApplication writes the workspace Application to the GitOps
// repository when one is designated, or applies it directly. A helm release
// already in place is left as it is: nothing is deleted during adoption.
func workspaceApplyApplication(ctx *cli.Context, root, repo, revision string, params []string) int {
	conf := filepath.Join(root, ".argocd.conf")
	gitops := confValue(conf, "argocd", "repo")
	var b bytes.Buffer
	if err := rule.RenderApplication(&b, "devzone-workspace", "workspace", config.NamespaceWorkspace,
		repo, revision, "charts/devzone-workspace", params, gitops); err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	if gitops == "" || gitops == "none" {
		return applyWorkspaceManifest(ctx, b.String())
	}
	if code := writeWorkspaceGitops(ctx, gitops, b.String()); code != 0 {
		return code
	}
	if code := runWorkstationArgoCD(ctx, "values-ensure"); code != 0 {
		return code
	}
	_, _ = ctx.Runner.Run(context.Background(), "kubectl", append(fexec.DevzoneContextFlag(context.Background(), ctx.Runner, "--context"),
		"-n", config.NamespaceArgoCD, "annotate", "application.argoproj.io", "devzone-workspace",
		"argocd.argoproj.io/refresh=normal", "--overwrite"), fexec.Opts{})
	return 0
}

// applyWorkspaceManifest applies one Application manifest through the
// injected Runner, without touching any other object of the cluster.
func applyWorkspaceManifest(ctx *cli.Context, manifest string) int {
	args := append(fexec.DevzoneContextFlag(context.Background(), ctx.Runner, "--context"),
		"apply", "-f", "-")
	res, err := ctx.Runner.Run(context.Background(), "kubectl", args,
		fexec.Opts{Stdin: strings.NewReader(manifest)})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(ctx.Err, err)
		} else {
			ctx.Err.Write(res.Stderr)
		}
		return 1
	}
	return 0
}

// writeWorkspaceGitops writes the Application file through the GitHub API:
// PUT with the blob SHA when it exists, POST when it is new.
func writeWorkspaceGitops(ctx *cli.Context, repo, manifest string) int {
	slug := strings.TrimSuffix(strings.TrimPrefix(repo, "https://github.com/"), ".git")
	path := "repos/" + slug + "/contents/apps/devzone-workspace.yaml"
	sha := ""
	res, err := ctx.Runner.Run(context.Background(), "gh",
		[]string{"api", path, "--jq", ".sha"}, fexec.Opts{})
	if err == nil && res.Code == 0 {
		sha = strings.TrimSpace(string(res.Stdout))
	}
	args := []string{"api"}
	if sha != "" {
		args = append(args, "-X", "PUT")
	} else {
		args = append(args, "-X", "POST")
	}
	args = append(args, path, "-f", "message=devzone: application devzone-workspace",
		"-f", "content="+base64.StdEncoding.EncodeToString([]byte(manifest)))
	if sha != "" {
		args = append(args, "-f", "sha="+sha)
	}
	res, err = ctx.Runner.Run(context.Background(), "gh", args, fexec.Opts{})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(ctx.Err, err)
		} else {
			ctx.Err.Write(res.Stderr)
		}
		return 1
	}
	return 0
}

// confValue returns the value of key in a section of a conf file, without
// loading the whole declaration: only the GitOps repository and the revision
// kept by the user are read this way by the launcher.
func confValue(path, section, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	current := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			current = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		if current != section {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
