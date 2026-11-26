package agent

import (
	"context"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
)

// AgentPodName returns "agent-<base>-<random>", lowercase (kubectl names).
func AgentPodName(base string) string {
	if base == "" {
		base = "session"
	} else {
		base = filepath.Base(base)
	}
	base = strings.ToLower(base)
	return "agent-" + base + "-" + itoa(rand.Intn(32768))
}

// AgentPodConfigMapName returns pod-consigne.
func AgentPodConfigMapName(podName string) string { return podName + "-consigne" }

// podCleaner tracks resources for cleanup (EXIT/INT/TERM), once.
type podCleaner struct {
	ctx      context.Context
	r        Runner
	name     string
	manifest string
	cleaned  bool
	journal  string
	stateDir string
}

func (c *podCleaner) cleanup() {
	if c.cleaned {
		return
	}
	c.cleaned = true
	if c.name != "" {
		kubectlSilent(c.ctx, c.r, "delete", "pod", c.name)
		kubectlSilent(c.ctx, c.r, "delete", "configmap", AgentPodConfigMapName(c.name))
	}
	if c.manifest != "" {
		os.Remove(c.manifest)
	}
}

func kubectlSilent(ctx context.Context, r Runner, args ...string) {
	if r == nil {
		return
	}
	r.Run(ctx, "kubectl", args, Opts{})
}

// AgentPodStatus lists session pods with limits (`agent status`).
func AgentPodStatus(ctx context.Context, r Runner, out io.Writer) {
	if r == nil {
		return
	}
	res, err := r.Run(ctx, "kubectl", []string{
		"get", "pods", "-l", "devzone.io/agent-session",
		"-o", `jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits.cpu}{"\t"}{.spec.containers[0].resources.limits.memory}{"\n"}{end}`,
	}, Opts{})
	if err != nil {
		return
	}
	fmt.Fprint(out, string(res.Stdout))
}

// PodWaitResult result of agent_pod_wait.
type PodWaitResult struct {
	Phase string
	OK    bool
}

// AgentPodWait waits for Succeeded/Failed; max DEVZONE_AGENT_POD_TIMEOUT.
func AgentPodWait(ctx context.Context, r Runner, podName string, clock Clock, maxWait int) PodWaitResult {
	elapsed := 0
	for elapsed < maxWait {
		phase := kubectlOut(ctx, r, "get", "pod", podName, "-o", "jsonpath={.status.phase}")
		if phase == "Succeeded" || phase == "Failed" {
			return PodWaitResult{Phase: phase, OK: true}
		}
		clock.Sleep(1e9) // 1 s
		elapsed++
	}
	phase := kubectlOut(ctx, r, "get", "pod", podName, "-o", "jsonpath={.status.phase}")
	if phase == "" {
		phase = "Unknown"
	}
	return PodWaitResult{Phase: phase, OK: false}
}

// AgentPodFetchLogs appends init container logs then agent log. Shell
// agent_pod_fetch_logs; kubectl failing logs -c not fatal.
func AgentPodFetchLogs(ctx context.Context, r Runner, podName, journalFile string) {
	var inits []string
	names := kubectlOut(ctx, r, "get", "pod", podName, "-o", "jsonpath={.spec.initContainers[*].name}")
	for _, n := range strings.Split(names, " ") {
		n = strings.TrimSpace(n)
		if n != "" {
			inits = append(inits, n)
		}
	}
	for _, initName := range inits {
		appendLine(journalFile, "=== init container "+initName+" ===")
		if r != nil {
			if res, err := r.Run(ctx, "kubectl", []string{"logs", podName, "-c", initName}, Opts{}); err == nil {
				appendFile(journalFile, string(res.Stdout))
			}
		}
	}
	if r != nil {
		if res, err := r.Run(ctx, "kubectl", []string{"logs", podName}, Opts{}); err == nil {
			appendFile(journalFile, string(res.Stdout))
		}
	}
}

// AgentPodInitFailure names init containers that terminated non-zero on stderr.
func AgentPodInitFailure(ctx context.Context, r Runner, podName string, errOut io.Writer) {
	cause := kubectlOut(ctx, r, "get", "pod", podName, "-o", `jsonpath={range .status.initContainerStatuses[?(@.state.terminated.exitCode)]}{.name}{" "}{.state.terminated.exitCode}{"\n"}{end}`)
	if strings.TrimSpace(cause) == "" {
		return
	}
	for _, line := range strings.Split(strings.TrimRight(cause, "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) == 0 || parts[0] == "" {
			continue
		}
		code := "0"
		if len(parts) > 1 {
			code = parts[1]
		}
		if code == "0" {
			continue
		}
		fmt.Fprintf(errOut, "devzone agent --pod : init container %s failed (exit %s)\n", parts[0], code)
	}
}

// AgentPodShowTail prints last 15 lines of log on stderr.
func AgentPodShowTail(journalFile string, errOut io.Writer) {
	data := readFileString(journalFile)
	lines := strings.Split(data, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > 15 {
		lines = lines[len(lines)-15:]
	}
	for _, l := range lines {
		fmt.Fprintln(errOut, l)
	}
}
