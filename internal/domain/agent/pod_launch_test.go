package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

func podSandbox(t *testing.T) (root, folder, consigne, state string, k *kubectlFake) {
	t.Helper()
	root = t.TempDir()
	folder = fauxWorktree(t, root, "devzone", "dz-222")
	consigne = filepath.Join(root, "consigne.txt")
	os.WriteFile(consigne, []byte("build the feature\n"), 0o644)
	state = t.TempDir()
	modules := filepath.Join(root, "modules")
	os.WriteFile(modules, nil, 0o644)
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	t.Setenv("DEVZONE_AGENT_POD_MODULES_FILE", modules)
	t.Setenv("DEVZONE_AGENT_POD_TIMEOUT", "1")
	k = &kubectlFake{resp: func(args []string) dzexec.Result {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, ".image}"):
			return dzexec.Result{Stdout: []byte("img")}
		case strings.Contains(joined, "PATH"):
			return dzexec.Result{Stdout: []byte("/bin")}
		case strings.Contains(joined, `name=="workspace"`):
			return dzexec.Result{Stdout: []byte("workspace-devzone-workspace-0")}
		case strings.Contains(joined, `name=="etat"`):
			return dzexec.Result{Stdout: []byte("etat-devzone-workspace-0")}
		case strings.Contains(joined, "{.status.phase}"):
			return dzexec.Result{Stdout: []byte(os.Getenv("FAKE_PHASE"))}
		case strings.HasPrefix(joined, "logs "):
			return dzexec.Result{Stdout: []byte("log line 1\nlast log line\n")}
		}
		return dzexec.Result{Code: 0}
	}}
	t.Setenv("FAKE_PHASE", "Succeeded")
	return root, folder, consigne, state, k
}

func hasCall(k *kubectlFake, substr string) bool {
	for _, c := range k.calls {
		if strings.Contains(strings.Join(c, " "), substr) {
			return true
		}
	}
	return false
}

func TestAgentPodLaunch(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	original := k.resp
	k.resp = func(args []string) dzexec.Result {
		if strings.HasPrefix(strings.Join(args, " "), "logs ") {
			var lines strings.Builder
			for i := 1; i <= 20; i++ {
				fmt.Fprintf(&lines, "log line %d\n", i)
			}
			return dzexec.Result{Stdout: []byte(lines.String())}
		}
		return original(args)
	}
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut)
	if code != 0 {
		t.Fatal("code", code, errOut.String())
	}
	if !hasCall(k, "create configmap") || !hasCall(k, "create -f") || !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("create/delete not called", k.calls)
	}
	journal := readFileString(state + "/dz-222.pod.log")
	if !strings.Contains(journal, "log line 1") || !strings.Contains(journal, "log line 20") || !strings.Contains(journal, "=== end of agent session in pod (phase: Succeeded)") {
		t.Fatal("journal", journal)
	}
	if !strings.Contains(errOut.String(), "log line 20") || strings.Contains(errOut.String(), "log line 1\n") {
		t.Fatalf("log tail on stderr: %q", errOut.String())
	}
}

func TestAgentPodLaunchCreateFails(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	k.resp = func(args []string) dzexec.Result {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "create -f") {
			return dzexec.Result{Code: 1}
		}
		if strings.Contains(joined, ".image}") {
			return dzexec.Result{Stdout: []byte("img")}
		}
		if strings.Contains(joined, "PATH") {
			return dzexec.Result{Stdout: []byte("/bin")}
		}
		return dzexec.Result{}
	}
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut)
	if code == 0 {
		t.Fatal("code 0")
	}
	if !strings.Contains(errOut.String(), "unable to create the pod") || !strings.Contains(errOut.String(), "try again without --pod") {
		t.Fatal("msg", errOut.String())
	}
	if !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("cleanup not called", k.calls)
	}
}

func TestAgentPodLaunchFailedPhase(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	t.Setenv("FAKE_PHASE", "Failed")
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut)
	if code == 0 {
		t.Fatal("code 0")
	}
	if !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("cleanup", k.calls)
	}
	if !strings.Contains(errOut.String(), "session ended in failure") {
		t.Fatal("msg", errOut.String())
	}
	if !strings.Contains(readFileString(state+"/dz-222.pod.log"), "last log line") {
		t.Fatal("log not kept")
	}
}

// TestAgentPodLaunchTimeout checks that a pod which never finishes is deleted,
// its log kept in the state directory and its tail shown on stderr.
func TestAgentPodLaunchTimeout(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	t.Setenv("FAKE_PHASE", "")
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	if code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut); code == 0 {
		t.Fatal("code 0")
	}
	if !strings.Contains(errOut.String(), "pod did not finish in time") || !strings.Contains(errOut.String(), "last log line") {
		t.Fatal("msg", errOut.String())
	}
	if !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("cleanup", k.calls)
	}
	if !strings.Contains(readFileString(state+"/dz-222.pod.log"), "last log line") {
		t.Fatal("log not kept")
	}
}

func TestAgentPodLaunchModulesFileMissing(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	os.Remove(os.Getenv("DEVZONE_AGENT_POD_MODULES_FILE"))
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut)
	if code == 0 || !strings.Contains(errOut.String(), "modules file missing") {
		t.Fatal("msg", code, errOut.String())
	}
	if hasCall(k, "create") {
		t.Fatal("created object", k.calls)
	}
}

func TestAgentPodLaunchNotInPod(t *testing.T) {
	_, folder, consigne, state, k := podSandbox(t)
	t.Setenv("DEVZONE_WORKSPACE", "")
	var errOut strings.Builder
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	if code := AgentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut); code == 0 {
		t.Fatal("code 0")
	}
	if !strings.Contains(errOut.String(), "must be called from the workspace pod") {
		t.Fatal("msg", errOut.String())
	}
}

// blockingClock keeps the wait pending until released, so an injected signal is
// the only way the session can end; no real sleep is used.
type blockingClock struct {
	release chan struct{}
}

// Now returns a fixed time.
func (b *blockingClock) Now() time.Time { return time.Unix(0, 0) }

// Sleep waits for the test to release the clock.
func (b *blockingClock) Sleep(time.Duration) { <-b.release }

// signalSandbox builds a session whose pod never reaches a final phase, so the
// injected signal decides the outcome.
func signalSandbox(t *testing.T) (folder, consigne, state string, k *kubectlFake, clock *blockingClock) {
	t.Helper()
	_, folder, consigne, state, k = podSandbox(t)
	original := k.resp
	k.resp = func(args []string) dzexec.Result {
		if strings.Contains(strings.Join(args, " "), "{.status.phase}") {
			return dzexec.Result{}
		}
		return original(args)
	}
	clock = &blockingClock{release: make(chan struct{})}
	t.Cleanup(func() { close(clock.release) })
	return folder, consigne, state, k, clock
}

// TestAgentPodLaunchInterrupt checks that INT during the wait deletes both
// objects and returns 130, as the shell trap did.
func TestAgentPodLaunchInterrupt(t *testing.T) {
	folder, consigne, state, k, clock := signalSandbox(t)
	sigCh := make(chan os.Signal, 1)
	sigCh <- os.Interrupt
	var errOut strings.Builder
	if code := agentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut, sigCh); code != 130 {
		t.Fatal("code", code)
	}
	if !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("cleanup not called", k.calls)
	}
}

// TestAgentPodLaunchTerminate checks that TERM during the wait deletes both
// objects and returns 143, as the shell trap did.
func TestAgentPodLaunchTerminate(t *testing.T) {
	folder, consigne, state, k, clock := signalSandbox(t)
	sigCh := make(chan os.Signal, 1)
	sigCh <- podTermSignal
	var errOut strings.Builder
	if code := agentPodLaunch(context.Background(), k, clock, folder, consigne, state, &errOut, sigCh); code != 143 {
		t.Fatal("code", code)
	}
	if !hasCall(k, "delete pod") || !hasCall(k, "delete configmap") {
		t.Fatal("cleanup not called", k.calls)
	}
}
