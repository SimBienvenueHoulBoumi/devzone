package podcmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

type jsonObj map[string]any

// runStateJSON prints machine status JSON with the stable schema 3 contract.
func runStateJSON(ctx *cli.Context, _ *state.State) int {
	root := devzoneRoot()
	errs := jsonObj{}
	alerts := []any{}
	out := jsonObj{
		"schema":       3,
		"devzone":      devzoneJSON(ctx, root),
		"git_identity": gitIdentityJSON(ctx),
		"platform":     platformJSON(ctx, errs),
		"argocd_repo":  argocdRepo(root),
		"tools":        jsonObj{"outdated": []any{}, "command": nil},
		"modules":      modulesJSON(root),
		"clusters":     clustersJSON(ctx),
		"ports":        portsJSON(ctx, errs),
		"applications": applicationsJSON(ctx),
		"credentials":  credentialsJSON(root),
		"alerts":       alerts,
		"errors":       errs,
	}
	enc := json.NewEncoder(ctx.Out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	return 0
}

func runCmd(ctx *cli.Context, name string, args ...string) (string, int, error) {
	res, err := ctx.Runner.Run(context.Background(), name, args, exec.Opts{})
	return string(res.Stdout), res.Code, err
}

func devzoneJSON(ctx *cli.Context, root string) jsonObj {
	script := filepath.Join(root, "manage", "scripts", "ci", "versions.sh")
	out, code, err := runCmd(ctx, "bash", script, "--version")
	version := any(nil)
	if err == nil && code == 0 {
		if v := strings.TrimSpace(out); v != "" {
			version = v
		}
	}
	available := any(nil)
	out, code, err = runCmd(ctx, "bash", script, "--published")
	if err == nil && code == 0 {
		if v := strings.TrimSpace(out); v != "" {
			available = v
		}
	}
	return jsonObj{"version": version, "available": available}
}

func gitIdentityJSON(ctx *cli.Context) jsonObj {
	name, _, _ := runCmd(ctx, "git", "config", "--get", "user.name")
	email, _, _ := runCmd(ctx, "git", "config", "--get", "user.email")
	name = strings.TrimSpace(name)
	email = strings.TrimSpace(email)
	ok := name != "" && email != ""
	var cmd any
	if !ok {
		cmd = "gh auth login -s workflow (automatic), or git config --file ~/.config/git/config user.name \"<name>\" and user.email \"<email>\""
	}
	return jsonObj{"ok": ok, "name": strOrNil(name), "email": strOrNil(email), "command": cmd}
}

func strOrNil(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func platformJSON(ctx *cli.Context, errs jsonObj) jsonObj {
	st := state.At(statePath())
	platform := st.Get("platform")
	if platform == "" {
		platform = "github"
	}
	var url any
	if platform == "gitlab" {
		if v := st.Get("gitlab_url"); v != "" {
			url = v
		}
	}
	var ghValue any
	if platform == "github" {
		out, code, _ := runCmd(ctx, "gh", "auth", "status")
		if code != 0 {
			ghValue = nil
			errs["github"] = "gh auth status failed"
		} else {
			workflow := true
			var ghCmd any
			if strings.Contains(out, "Token scopes:") && !strings.Contains(out, "'workflow'") {
				workflow = false
				ghCmd = "gh auth refresh -h github.com -s workflow"
			}
			ghValue = jsonObj{"connected": true, "workflow": workflow, "command": ghCmd}
		}
	}
	return jsonObj{"name": platform, "url": url, "github": ghValue}
}

func argocdRepo(root string) any {
	data, err := os.ReadFile(filepath.Join(root, ".argocd.conf"))
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "repo = ") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "repo = "))
			if v != "" {
				return v
			}
		}
	}
	return nil
}

func modulesJSON(root string) []any {
	mods := []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}
	st := state.At(statePath())
	out := make([]any, 0, len(mods))
	for _, m := range mods {
		active := st.Get(m) == "on"
		desc := moduleDesc(m)
		var stateVal any = "optional"
		var failed any
		var cmd any = "devzone enable " + m
		if active {
			cmd = nil
			stateVal = "active"
			failedPath := statePath() + "-failed-" + m
			if b, err := os.ReadFile(failedPath); err == nil {
				failed = strings.TrimSpace(string(b))
				stateVal = "failed"
				cmd = "devzone apply"
			}
		}
		_ = root
		out = append(out, jsonObj{"name": m, "active": active, "description": desc, "state": stateVal, "failed": failed, "command": cmd})
	}
	return out
}

func moduleDesc(m string) string {
	switch m {
	case "ai":
		return "AI assistants: Claude Code, opencode"
	case "kubernetes":
		return "connection to the host cluster and metrics-server at startup"
	case "gitlab":
		return "test GitLab in the services cluster"
	case "postgres":
		return "shared PostgreSQL, one database per project"
	case "argocd":
		return "Argo CD, deployment interface of the services cluster"
	case "mysql":
		return "shared MySQL, one database per project"
	default:
		return ""
	}
}

func clustersJSON(ctx *cli.Context) jsonObj {
	st := state.At(statePath())
	var services any
	if v := st.Get("cluster"); v != "" {
		services = v
	}
	workOut, _, _ := runCmd(ctx, "kubectl", "config", "current-context")
	work := strings.TrimSpace(workOut)
	return jsonObj{"services": services, "services_remote": false, "work": strOrNil(work), "internal_work": false, "command": nil}
}

func portsJSON(ctx *cli.Context, errs jsonObj) any {
	script := filepath.Join(codeRoot(), "ports.sh")
	out, code, err := runCmd(ctx, "bash", script, "list", "--json")
	if err != nil || code != 0 {
		errs["ports"] = "ports.sh unavailable"
		return nil
	}
	var v any
	if json.Unmarshal([]byte(out), &v) != nil {
		errs["ports"] = "ports output unreadable"
		return nil
	}
	return v
}

func applicationsJSON(ctx *cli.Context) any {
	script := filepath.Join(codeRoot(), "catalog.sh")
	out, code, err := runCmd(ctx, "bash", script, "json")
	if err != nil || code != 0 {
		return []any{}
	}
	var v any
	if json.Unmarshal([]byte(out), &v) != nil {
		return []any{}
	}
	return v
}

func credentialsJSON(root string) any {
	p := filepath.Join(root, ".password")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return nil
}
