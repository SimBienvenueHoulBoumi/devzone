package agent

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// AgentInPod true in the workspace container (DEVZONE_WORKSPACE=kubernetes).
func AgentInPod() bool { return os.Getenv("DEVZONE_WORKSPACE") == "kubernetes" }

// AgentKC kubectl of the workstation: devzone context if it exists, then
// workspace namespace. Shell agent_kc; kubectl via Runner.
func AgentKC(ctx context.Context, r Runner, args ...string) Result {
	if r == nil {
		return Result{Code: 1}
	}
	prefix := append(fexec.DevzoneContextFlag(ctx, r, "--context"), "--namespace", config.NamespaceWorkspace)
	full := append(prefix, args...)
	res, err := r.Run(ctx, "kubectl", full, Opts{})
	if err != nil {
		return Result{Code: 1, Stderr: []byte(err.Error())}
	}
	return res
}

// WorkspaceAvailable true when workspace pod runs and command from workstation.
func WorkspaceAvailable(ctx context.Context, r Runner) bool {
	if AgentInPod() {
		return false
	}
	res := AgentKC(ctx, r, "get", "pod", "devzone-workspace-0", "-o", "jsonpath={.status.phase}", "--request-timeout=5s")
	return res.Code == 0 && strings.TrimSpace(string(res.Stdout)) == "Running"
}

// AgentHelp text (agent-workspace.sh agent_help).
func AgentHelp() string {
	return `usage: devzone agent [--model <m>[,<m2>…]] [--local] <folder> <brief-file>
        runs opencode on the brief, free models in rotation
        --model: models tried first, in order, then the rotation
        Kubernetes workspace first if it runs; --local: this container
        a /workspaces/projets/... path absent from here is a folder of the pod, without copy
        devzone agent state [--json]
        known sessions and excluded models
        devzone agent release [<model>|--all]
        lifts a model exclusion
`
}

// AgentWorkspace runs brief in pod, brings journal back even on failure.
// Shell agent_workspace; kubectl via Runner. Returns exit code.
func AgentWorkspace(ctx context.Context, r Runner, out io.Writer, errOut io.Writer, folder, brief, racine, modelList, journalPath string) int {
	name := ""
	inPod := ""
	podRoot := "/home/vscode/.local/share/devzone"
	if strings.HasPrefix(folder, "/workspaces/projets/") {
		if !dirExists(folder) {
			inPod = folder
		}
	}
	if inPod != "" {
		name = filepath.Base(inPod)
		res := AgentKC(ctx, r, "exec", "devzone-workspace-0", "-c", "workspace", "--", "test", "-d", inPod)
		if res.Code != 0 {
			fmt.Fprintln(errOut, "devzone agent: folder not found in the pod: "+inPod+" (devzone workspace clone, then devzone ticket <n> in the pod)")
			return 2
		}
	} else {
		if !dirExists(folder) {
			fmt.Fprintln(errOut, "devzone agent: folder not found: "+folder+" (searched from "+cwd()+")")
			return 2
		}
		name = filepath.Base(absPath(folder))
		inPod = "/workspaces/projets/" + name
		res := AgentKC(ctx, r, "exec", "devzone-workspace-0", "-c", "workspace", "--", "test", "-d", inPod)
		if res.Code != 0 {
			fmt.Fprintln(errOut, "devzone agent: project "+name+" missing from the Kubernetes workspace: devzone workspace copy-to "+folder+" (on this machine), or --local")
			return 2
		}
	}
	fmt.Fprintln(out, "devzone agent: Kubernetes workspace (pod devzone-workspace-0, "+inPod+"); --local for the container")
	AgentKC(ctx, r, "cp", brief, "devzone-workspace-0:/tmp/devzone-agent-"+name+".md", "-c", "workspace")
	res := AgentKC(ctx, r, "exec", "devzone-workspace-0", "-c", "workspace", "--", "env", "DEVZONE_ROOT="+podRoot, "MODEL_OPT="+modelList, "bash", "-lc", "ulimit -c 0; devzone agent ${MODEL_OPT:+--model \"$MODEL_OPT\"} \"$1\" \"$2\"", "_", inPod, "/tmp/devzone-agent-"+name+".md")
	code := res.Code
	journal := JournalOf(racine, name)
	os.MkdirAll(filepath.Dir(journal), 0o755)
	resCat := AgentKC(ctx, r, "exec", "devzone-workspace-0", "-c", "workspace", "--", "cat", podRoot+"/workspace/.agents/"+name+".log")
	if resCat.Code != 0 {
		appendLine(journal, "=== pod journal not found")
	} else {
		appendFile(journal, string(resCat.Stdout))
	}
	_ = journalPath
	return code
}

// appendFile appends raw data to a file.
func appendFile(p, data string) {
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(data)
}

func cwd() string {
	d, _ := os.Getwd()
	return d
}

func absPath(p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	wd, _ := os.Getwd()
	return filepath.Clean(filepath.Join(wd, p))
}
