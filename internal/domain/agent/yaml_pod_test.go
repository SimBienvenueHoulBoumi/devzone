package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestYAMLPodValid checks the five yaml_valid fixtures of the removed bats:
// a valid Pod, broken syntax, a non-Pod, a Pod without a name and one without
// containers.
func TestYAMLPodValid(t *testing.T) {
	cases := []struct {
		name string
		text string
		want bool
	}{
		{"valid", "apiVersion: v1\nkind: Pod\nmetadata:\n  name: dz-222\nspec:\n  containers:\n  - name: agent\n    image: busybox\n", true},
		{"broken", "apiVersion: v1\nkind: Pod\nmetadata: [unclosed\n  name: \"dz-222\nspec:\n  containers:\n  - name: agent\n", false},
		{"not a pod", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: dz-222\nspec:\n  containers:\n  - name: agent\n", false},
		{"no name", "apiVersion: v1\nkind: Pod\nmetadata:\n  labels:\n    app: dz\nspec:\n  containers:\n  - name: agent\n", false},
		{"no containers", "apiVersion: v1\nkind: Pod\nmetadata:\n  name: dz-222\nspec:\n  containers: []\n", false},
	}
	for _, c := range cases {
		if got := YAMLPodValid([]byte(c.text)); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// TestBuildManifestYAMLValid checks that the manifest built from a worktree is
// accepted by the same Pod validation as the removed yaml_valid helper.
func TestBuildManifestYAMLValid(t *testing.T) {
	root := t.TempDir()
	folder := fauxWorktree(t, root, "devzone", "dz-222")
	st, ok := AgentPodValidateFolder(folder, root, nil)
	if !ok {
		t.Fatal("invalid folder")
	}
	mf, err := BuildManifest(context.Background(), podKubectl(), folder, "agent-dz-222-test", st)
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(mf)
	data, err := os.ReadFile(mf)
	if err != nil {
		t.Fatal(err)
	}
	if !YAMLPodValid(data) {
		t.Fatalf("built manifest is not a valid Pod:\n%s", data)
	}
	if filepath.Ext(mf) != ".yaml" {
		t.Fatal("manifest extension", mf)
	}
}

// TestBuildManifestValidWithSpecialConsigne checks that a brief holding quotes,
// colons and newlines still yields a valid Pod and is not embedded in it.
func TestBuildManifestValidWithSpecialConsigne(t *testing.T) {
	root := t.TempDir()
	folder := fauxWorktree(t, root, "devzone", "dz-223")
	st, ok := AgentPodValidateFolder(folder, root, nil)
	if !ok {
		t.Fatal("invalid folder")
	}
	consigne := filepath.Join(root, "consigne.md")
	os.WriteFile(consigne, []byte("say \"hello: world\"\nsecond: line\n"), 0o644)
	k := &kubectlFake{resp: func(args []string) dzexec.Result {
		switch {
		case containsStr(strings.Join(args, " "), ".image}"):
			return dzexec.Result{Stdout: []byte("img")}
		case containsStr(strings.Join(args, " "), "PATH"):
			return dzexec.Result{Stdout: []byte("/bin")}
		case containsStr(strings.Join(args, " "), `name=="workspace"`):
			return dzexec.Result{Stdout: []byte("workspace-devzone-workspace-0")}
		case containsStr(strings.Join(args, " "), `name=="etat"`):
			return dzexec.Result{Stdout: []byte("etat-devzone-workspace-0")}
		}
		return dzexec.Result{}
	}}
	mf, err := BuildManifest(context.Background(), k, folder, "agent-dz-223-test", st)
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(mf)
	data, err := os.ReadFile(mf)
	if err != nil {
		t.Fatal(err)
	}
	if !YAMLPodValid(data) {
		t.Fatalf("manifest invalid:\n%s", data)
	}
	if strings.Contains(string(data), "hello: world") {
		t.Fatal("consigne content embedded in manifest")
	}
}

// TestAgentPodTimeoutDefault checks that the default wait is deadline + 120 s.
func TestAgentPodTimeoutDefault(t *testing.T) {
	t.Setenv("DEVZONE_AGENT_POD_TIMEOUT", "")
	t.Setenv("DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS", "")
	if got := AgentPodTimeout(); got != "1920" {
		t.Fatal("default timeout", got)
	}
	t.Setenv("DEVZONE_AGENT_POD_TIMEOUT", "7")
	if got := AgentPodTimeout(); got != "7" {
		t.Fatal("explicit timeout", got)
	}
}
