package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// podKubectl returns a scripted kubectl answering the lookups of a manifest build.
func podKubectl() *kubectlFake {
	return &kubectlFake{resp: func(args []string) dzexec.Result {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, ".image}"):
			return dzexec.Result{Stdout: []byte("ghcr.io/test/workspace:1.0")}
		case strings.Contains(joined, "PATH"):
			return dzexec.Result{Stdout: []byte("/test/path:/usr/bin:/bin")}
		case strings.Contains(joined, `name=="workspace"`):
			return dzexec.Result{Stdout: []byte("workspace-devzone-workspace-0")}
		case strings.Contains(joined, `name=="etat"`):
			return dzexec.Result{Stdout: []byte("etat-devzone-workspace-0")}
		case strings.Contains(joined, "egress-proxy"):
			return dzexec.Result{Stdout: []byte("")}
		}
		return dzexec.Result{Code: 0}
	}}
}

// TestBuildManifest checks the Pod manifest against the shell fixture: mounts,
// labels, limits, command, and no gh/claude/kubeconfig or consigne content.
func TestBuildManifest(t *testing.T) {
	root := t.TempDir()
	folder := fauxWorktree(t, root, "devzone", "dz-222")
	st, ok := AgentPodValidateFolder(folder, root, nil)
	if !ok {
		t.Fatal("invalid")
	}
	k := podKubectl()
	mf, err := BuildManifest(context.Background(), k, folder, "agent-dz-222-test", st)
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(mf)
	data := readFileString(mf)
	for _, want := range []string{
		"kind: Pod", "devzone.io/agent-session: dz-222", `devzone.io/agent-ticket: "222"`,
		"statefulset.kubernetes.io/pod-name", "devzone-workspace-0", "topologyKey: kubernetes.io/hostname",
		"automountServiceAccountToken: false", "restartPolicy: Never", "activeDeadlineSeconds: 1800",
		"cpu: 2", "memory: 4Gi", "image: ghcr.io/test/workspace:1.0",
		"subPath: devzone-wt/dz-222", "mountPath: " + folder, "subPath: devzone/.git", "mountPath: " + filepath.Join(root, "devzone", ".git"),
		"name: agent-dz-222-test-consigne", "mountPath: /agent-consigne", "readOnly: true",
		"mountPath: /workspaces/projets/.devzone.modules", "subPath: .devzone.modules",
		"devzone agent --local " + folder + " /agent-consigne/consigne.md", "exit \\$code",
		"value: \"kubernetes\"", `value: "/workspaces/projets"`,
		"claimName: workspace-devzone-workspace-0", "claimName: etat-devzone-workspace-0",
		"emptyDir:", "sizeLimit: 256Mi", "mountPath: /workspaces/projets/workspace",
		"mountPath: /workspaces/projets/.devzone.modules",
	} {
		if !strings.Contains(data, want) {
			t.Fatal("missing", want, "\n"+data)
		}
	}
	if strings.Contains(data, "subPath: /") {
		t.Fatal("subPath starts with /")
	}
	if strings.Contains(data, ".config/gh") || strings.Contains(data, "/.claude") || strings.Contains(data, "kubeconfig") {
		t.Fatal("gh/claude/kubeconfig mounted")
	}
	if strings.Contains(data, "secret consigne") {
		t.Fatal("consigne in manifest")
	}
	found := false
	for _, c := range k.calls {
		if strings.Contains(strings.Join(c, " "), "get service -l app.kubernetes.io/component=egress-proxy") {
			found = true
		}
		if strings.Contains(strings.Join(c, " "), "get service egress-proxy") {
			t.Fatal("get service egress-proxy used")
		}
	}
	if !found {
		t.Fatal("egress list not called")
	}
}

// TestEgressModes checks observation and strict proxy env and the fail-closed guard.
func TestEgressModes(t *testing.T) {
	root := t.TempDir()
	folder := fauxWorktree(t, root, "devzone", "dz-220")
	st, _ := AgentPodValidateFolder(folder, root, nil)
	for _, mode := range []string{"", "observation", "strict"} {
		k := podKubectl()
		k.resp = func(args []string) dzexec.Result {
			joined := strings.Join(args, " ")
			if strings.Contains(joined, "egress-proxy") && strings.Contains(joined, "egress-mode") {
				return dzexec.Result{Stdout: []byte(mode)}
			}
			if strings.Contains(joined, ".image}") {
				return dzexec.Result{Stdout: []byte("img")}
			}
			if strings.Contains(joined, "PATH") {
				return dzexec.Result{Stdout: []byte("/bin")}
			}
			return dzexec.Result{}
		}
		mf, _ := BuildManifest(context.Background(), k, folder, "p", st)
		data := readFileString(mf)
		os.Remove(mf)
		if mode == "" {
			if strings.Contains(data, "HTTP_PROXY") || strings.Contains(data, "initContainers") {
				t.Fatal("no proxy mode has proxy/init")
			}
		} else {
			if !strings.Contains(data, `value: "http://egress-proxy:3128"`) || !strings.Contains(data, `value: "localhost,127.0.0.1,.svc,.cluster.local"`) {
				t.Fatal("proxy env missing", mode)
			}
			if mode == "strict" {
				if !strings.Contains(data, "wait-egress-restriction") || !strings.Contains(data, "initContainers") {
					t.Fatal("strict init missing")
				}
				if !strings.Contains(data, `curl --noproxy "*" -m 3`) || !strings.Contains(data, "https://opencode.ai") || !strings.Contains(data, "egress restriction never became effective: session refused") {
					t.Fatal("guard command")
				}
			} else if strings.Contains(data, "wait-egress-restriction") || strings.Contains(data, "initContainers") {
				t.Fatal("observation has init")
			}
		}
	}
}

// TestAgentPodWait checks that a final phase ends the wait without a real sleep.
func TestAgentPodWait(t *testing.T) {
	clock := &FakeClock{NowTime: time.Unix(0, 0)}
	k := &kubectlFake{resp: func(args []string) dzexec.Result {
		if strings.Contains(strings.Join(args, " "), "{.status.phase}") {
			return dzexec.Result{Stdout: []byte("Succeeded")}
		}
		return dzexec.Result{}
	}}
	res := AgentPodWait(context.Background(), k, "p", clock, 1)
	if !res.OK || res.Phase != "Succeeded" {
		t.Fatal("wait", res)
	}
}

// TestAgentPodInitFailure names only init containers that exited non-zero.
func TestAgentPodInitFailure(t *testing.T) {
	var sb strings.Builder
	k := &kubectlFake{resp: func(args []string) dzexec.Result {
		if strings.Contains(strings.Join(args, " "), "initContainerStatuses") {
			return dzexec.Result{Stdout: []byte("premier-ok 0\nguard-failed 1\n")}
		}
		return dzexec.Result{}
	}}
	AgentPodInitFailure(context.Background(), k, "p", &sb)
	out := sb.String()
	if !strings.Contains(out, "init container guard-failed failed (exit 1)") {
		t.Fatal("failed not named", out)
	}
	if strings.Contains(out, "premier-ok failed") {
		t.Fatal("successful named", out)
	}
}

// TestAgentPodStatus checks the listing of session pods with their limits.
func TestAgentPodStatus(t *testing.T) {
	var sb strings.Builder
	k := &kubectlFake{resp: func(args []string) dzexec.Result {
		if len(args) > 0 && args[0] == "get" && args[1] == "pods" {
			return dzexec.Result{Stdout: []byte("agent-x\t2\t4Gi\n")}
		}
		return dzexec.Result{}
	}}
	AgentPodStatus(context.Background(), k, &sb)
	if !strings.Contains(sb.String(), "2") || !strings.Contains(sb.String(), "4Gi") {
		t.Fatal("status", sb.String())
	}
}
