package workspace

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// imageRepo returns the workspace image repository from the shared install
// configuration, so start, update and egress see the same environment override.
func imageRepo() string { return config.ImageRepo() }

// EgressEnv holds what a workspace egress command touches. Everything that
// would reach the machine is injected: the Runner for kubectl, the modules
// file, the deploy callback that belongs to the start command, and sleep.
type EgressEnv struct {
	Runner   Runner
	Modules  string
	Out      io.Writer
	ErrOut   io.Writer
	Deploy   func(repository, tag, revision string) int
	Sleep    func(time.Duration)
	LookPath func(string) (string, error)
}

// ready checks the cluster with the injected program lookup, or with the real
// PATH when the caller did not inject one.
func (e EgressEnv) ready() (string, bool) {
	look := e.LookPath
	if look == nil {
		look = exec.LookPath
	}
	return kubeEnv{runner: e.Runner, lookPath: look}.ready(true)
}

// Run dispatches observation, strict, off, status, allow and deny, as
// egress_workspace in manage/scripts/workspace/workspace-egress.sh.
func (e EgressEnv) Run(args []string) int {
	if e.Sleep == nil {
		e.Sleep = time.Sleep
	}
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "observation", "strict", "off":
		return e.setMode(sub)
	case "status":
		look := e.LookPath
		if look == nil {
			look = exec.LookPath
		}
		return egressStatus(kubeEnv{runner: e.Runner, lookPath: look}, e.Out, e.ErrOut)
	case "allow", "deny":
		if len(args) != 2 {
			fmt.Fprintf(e.ErrOut, "✖ egress %s takes one domain: devzone workspace egress %s <domain>\n", sub, sub)
			return 1
		}
		return e.edit(sub, args[1])
	default:
		fmt.Fprintf(e.ErrOut, "✖ unknown egress argument: %s (devzone workspace egress observation|strict|off|status|allow <domain>|deny <domain>)\n", none(sub))
		return 1
	}
}

// none is the shell's ${1:-none}: an absent argument is shown as none.
func none(value string) string {
	if value == "" {
		return "none"
	}
	return value
}

// setMode memorises the mode only after the cluster is checked, then redeploys
// the workspace at the image it already runs.
func (e EgressEnv) setMode(mode string) int {
	if reason, ok := e.ready(); !ok {
		fmt.Fprintln(e.ErrOut, reason)
		return 1
	}
	if err := noteModulesKey(e.Modules, "egress", mode); err != nil {
		fmt.Fprintf(e.ErrOut, "✖ cannot write %s: %v\n", e.Modules, err)
		return 1
	}
	if status := e.redeploy(); status != 0 {
		return status
	}
	fmt.Fprintf(e.Out, "✔ egress %s\n", mode)
	if mode == "strict" {
		fmt.Fprintln(e.Out, "ℹ strict: only the devzone agent sessions started with --pod are filtered; the workspace stays open")
	}
	return 0
}

// edit adds or removes an added domain. The base list is never changed.
func (e EgressEnv) edit(action, domain string) int {
	out, errOut, next, changed, status := egressEdit(action, domain, readModulesKey(e.Modules, "egress_domains"))
	fmt.Fprint(e.Out, out)
	fmt.Fprint(e.ErrOut, errOut)
	if status != 0 || !changed {
		return status
	}
	if reason, ok := e.ready(); !ok {
		fmt.Fprintln(e.ErrOut, reason)
		return 1
	}
	if err := noteModulesKey(e.Modules, "egress_domains", next); err != nil {
		fmt.Fprintf(e.ErrOut, "✖ cannot write %s: %v\n", e.Modules, err)
		return 1
	}
	fmt.Fprintf(e.Out, "✔ %s %s\n", action, domain)
	return e.redeploy()
}

// currentApplication returns the revision and the image tag of the workspace
// Application, or two empty strings when the workspace was installed by helm
// direct (update_current in workspace-update.sh).
func (e EgressEnv) currentApplication() (string, string) {
	flag := contextFlag(e.Runner)
	text := kubectlText(e.Runner, append(flag, "-n", "devzone-argocd", "get", "application.argoproj.io",
		"devzone-workspace", "-o", `jsonpath={.spec.source.targetRevision} {.spec.source.helm.parameters[?(@.name=="image.tag")].value}`))
	fields := strings.Fields(text)
	if len(fields) < 2 {
		return "", ""
	}
	return fields[0], fields[1]
}

// redeploy applies the setting at the image of the running Application, then
// waits for the proxy when it is on. Without Application, the setting is only
// kept and the next start applies it.
func (e EgressEnv) redeploy() int {
	revision, tag := e.currentApplication()
	if revision == "" || tag == "" {
		fmt.Fprintln(e.Out, "ℹ no Argo CD Application: the setting is kept, devzone workspace start applies it")
		return 0
	}
	if e.Deploy == nil {
		return 1
	}
	if status := e.Deploy(imageRepo(), tag, revision); status != 0 {
		return status
	}
	if EgressParams(e.Modules) == "" {
		return 0
	}
	fmt.Fprintln(e.Out, "▶ waiting for the egress proxy…")
	return e.waitProxy()
}

// waitProxy waits for the Deployment created by Argo CD, then for its rollout,
// as egress_wait_proxy. The pauses are injected, so a test never waits for a
// real proxy: it advances a counter instead.
func (e EgressEnv) waitProxy() int {
	limit := egressSeconds("DEVZONE_EGRESS_WAIT", 90)
	rollout := egressSeconds("DEVZONE_EGRESS_ROLLOUT", 120)
	step := egressSeconds("DEVZONE_EGRESS_STEP", 3)
	flag := contextFlag(e.Runner)
	args := append(flag, "-n", namespace, "get", "deployment", "devzone-workspace-egress-proxy")
	waited := 0
	for {
		status, err := e.Runner.Kubectl(args, nil, io.Discard, io.Discard)
		if err == nil && status == 0 {
			break
		}
		if waited >= limit {
			fmt.Fprintf(e.ErrOut, "⚠ the egress proxy was not created by Argo CD after %d s: the setting is kept, check devzone workspace argocd status\n", limit)
			return 1
		}
		pause := step
		if limit-waited < pause {
			pause = limit - waited
		}
		e.Sleep(time.Duration(pause) * time.Second)
		waited += pause
	}
	args = append(flag, "-n", namespace, "rollout", "status", "deployment/devzone-workspace-egress-proxy",
		"--timeout="+strconv.Itoa(rollout)+"s")
	status, err := e.Runner.Kubectl(args, nil, io.Discard, io.Discard)
	if err != nil || status != 0 {
		fmt.Fprintf(e.ErrOut, "⚠ egress proxy not ready after %d s: the setting is kept, see devzone workspace egress status\n", rollout)
		return 1
	}
	return 0
}

// egressSeconds reads a whole number of seconds with the shell default.
func egressSeconds(key string, fallback int) int {
	value, err := strconv.Atoi(os.Getenv(key))
	if err != nil || value < 0 {
		return fallback
	}
	return value
}
