package ai

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// llmRemoved is the migration message of the removed local model module.
const llmRemoved = "devzone : llm module removed: devzone no longer hosts a model; the host (Ollama) models are detected instead (devzone ai). To free the disk: kubectl delete namespace devzone-llm"

// stateCommand calls the state command with the instance state file.
func stateCommand(ctx context.Context, o Options, args ...string) dzexec.Result {
	opts := dzexec.Opts{}
	if o.StateFile != "" {
		opts.Env = []string{"DEVZONE_STATE=" + o.StateFile}
	}
	res, err := o.runner().Run(ctx, "devzone", args, opts)
	if err != nil {
		res.Code = 127
	}
	return res
}

// migrateLLM drops the old state line and announces the migration once.
func migrateLLM(ctx context.Context, o Options) {
	data, err := os.ReadFile(o.StateFile)
	if err != nil || !strings.Contains(string(data), "llm=") {
		return
	}
	stateCommand(ctx, o, "state", "remove", "llm")
	fmt.Fprintln(o.out(), llmRemoved)
}

// skillModel returns the versioned skill template of the installed code.
func skillModel(o Options) string {
	return filepath.Join(o.devcontainerDir(), "skills", "devzone", "SKILL.md")
}

// ApplyOn installs the assistants and everything they need.
func ApplyOn(ctx context.Context, o Options) int {
	fmt.Fprintln(o.out(), "devzone : installing Claude Code and opencode (a few minutes)…")
	failed := installAssistants(ctx, o)
	if len(failed) > 0 {
		log := lastNpmLog(o.home())
		marker := o.failureMarker("ai")
		os.MkdirAll(filepath.Dir(marker), 0o755)
		os.WriteFile(marker, []byte("npm log: "+log+"\n"), 0o644)
		fmt.Fprintf(o.errOut(), "devzone : installation of %s failed (npm install -g, 3 tries); npm log: %s; retry: devzone apply\n", strings.Join(failed, " "), log)
		return 1
	}
	os.Remove(o.failureMarker("ai"))
	fmt.Fprintln(o.out(), "devzone : Claude Code and opencode installed")
	if res, err := o.runner().Run(ctx, "repowarden", []string{"agents", "init", "--global"}, dzexec.Opts{}); err == nil && res.Code == 0 {
		fmt.Fprintln(o.out(), "devzone : repowarden guard active for Claude Code and opencode")
	} else {
		fmt.Fprintln(o.errOut(), "devzone : repowarden guard not connected (repowarden 4.10 or later required): repowarden agents init --global")
	}
	InstallGuardHooks(o)
	InstallOpencodeConfig(o)
	UnsetProvider(o)
	SetProvider(ctx, o)
	names := Models(ctx, o)
	if len(names) == 0 {
		fmt.Fprintf(o.out(), "devzone : no Ollama model detected on %s (host models not connected)\n", o.url())
	} else {
		fmt.Fprintf(o.out(), "devzone : %d model(s) of the host (Ollama) connected\n", len(names))
	}
	InstallSkill(o, skillModel(o))
	fmt.Fprintln(o.out(), "devzone : ai active: claude (then /login), opencode auth login")
	return 0
}

// ApplyOff removes the assistants and what devzone installed for them.
func ApplyOff(ctx context.Context, o Options) int {
	uninstallAssistants(ctx, o)
	os.Remove(o.failureMarker("ai"))
	if res, err := o.runner().Run(ctx, "repowarden", []string{"agents", "retirer", "--global"}, dzexec.Opts{}); err != nil || res.Code != 0 {
		removeRepowardenHooks(o)
	}
	removeRepowardenPlugins(o)
	RemoveGuardHooks(o)
	RemoveOpencodeConfig(o)
	UnsetProvider(o)
	RemoveSkill(o, skillModel(o))
	fmt.Fprintln(o.out(), "devzone : ai disabled (logins and devzone agent state kept in their volumes; workspace/.agents/ logs kept)")
	return 0
}

// Enable writes the module state then applies the assistant part.
func Enable(ctx context.Context, o Options) int {
	migrateLLM(ctx, o)
	if stateCommand(ctx, o, "state", "write", "ai", "on").Code != 0 {
		return 1
	}
	return ApplyOn(ctx, o)
}

// Disable writes the module state then removes the assistant part.
func Disable(ctx context.Context, o Options) int {
	migrateLLM(ctx, o)
	if stateCommand(ctx, o, "state", "write", "ai", "off").Code != 0 {
		return 1
	}
	return ApplyOff(ctx, o)
}
