package command

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestHostDockerStoppedStopsBeforeInventory: with Docker stopped, the command says
// so once and stops; no container, image or volume is looked at.
func TestHostDockerStoppedStopsBeforeInventory(t *testing.T) {
	root := devzoneDir(t, "postgres=on")
	runner := fake.New()
	runner.OnResponse("docker", []string{"info"}, fake.Response{
		Stderr: []byte("failed to connect to the docker API"), Code: 1,
	})
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if strings.Count(errOut, "Start Docker Desktop") != 1 || !strings.Contains(errOut, "then run devzone uninstall again") {
		t.Fatalf("stderr = %q", errOut)
	}
	if got := dockerCalls(runner); len(got) != 1 || got[0] != "info" {
		t.Fatalf("docker calls = %v, want only info", got)
	}
}

// TestHostRemovesFolderResourcesInOrder: the folder's container, image and
// volumes, the kind cluster, the network and the labeled container are removed,
// each once, in the order of the shell uninstaller.
func TestHostRemovesFolderResourcesInOrder(t *testing.T) {
	root := devzoneDir(t, "postgres=on")
	runner := folderRunner(t, root)
	code, out, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	want := []string{
		"info", "ps -aq --filter label=devcontainer.local_folder=" + root,
	}
	calls := dockerCalls(runner)
	if len(calls) < len(want) || calls[0] != want[0] {
		t.Fatalf("docker calls = %v", calls)
	}
	order := []string{"rm -f c1", "rmi vsc-img", "volume rm dind-vol", "volume rm devzone-m2", "volume rm devzone-gh",
		"rm -f k1", "network rm kind", "rm -f l1"}
	last := -1
	for _, cmd := range order {
		idx := indexOf(calls, cmd)
		if idx < 0 {
			t.Fatalf("missing call %q in %v", cmd, calls)
		}
		if idx <= last {
			t.Fatalf("call %q out of order in %v", cmd, calls)
		}
		last = idx
	}
	if count(calls, "rm -f c1") != 1 {
		t.Fatalf("container c1 removed more than once: %v", calls)
	}
	for _, line := range []string{"✔ container removed: c1", "✔ image removed: vsc-img", "✔ volume removed: dind-vol",
		"✔ kind cluster container removed: k1", "✔ kind Docker network removed", "✔ labeled container removed: l1",
		"✔ file removed: .devzone.modules"} {
		if !strings.Contains(out, line) {
			t.Fatalf("output lacks %q:\n%s", line, out)
		}
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); !os.IsNotExist(err) {
		t.Fatalf("state file kept after a full removal: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "workspace")); err != nil {
		t.Fatalf("workspace removed: %v", err)
	}
}

// TestHostKeepsLoginsWithKeep: KEEP=logins keeps the logins volume and removes
// the other one, and the plan says so.
func TestHostKeepsLoginsWithKeep(t *testing.T) {
	root := devzoneDir(t)
	t.Setenv("KEEP", "logins")
	runner := folderRunner(t, root)
	code, out, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if indexOf(dockerCalls(runner), "volume rm devzone-gh") >= 0 {
		t.Fatal("login volume removed with KEEP=logins")
	}
	if indexOf(dockerCalls(runner), "volume rm devzone-m2") < 0 {
		t.Fatal("non-login volume kept with KEEP=logins")
	}
	if !strings.Contains(out, "Kept (KEEP=logins):\n  devzone-gh") {
		t.Fatalf("kept volume not reported:\n%s", out)
	}
}

// TestHostRefusesUnknownKeep: an unknown KEEP value stops the command before
// any Docker call, with the shell's message.
func TestHostRefusesUnknownKeep(t *testing.T) {
	root := devzoneDir(t)
	t.Setenv("KEEP", "all")
	runner := folderRunner(t, root)
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 1 || !strings.Contains(errOut, "KEEP: unknown value: all (only value: logins)") {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if len(runner.Calls()) != 0 {
		t.Fatalf("calls = %v, want none", runner.Calls())
	}
}

// TestHostNothingRemovedWithoutConfirmation: without --yes, CONFIRM or a
// terminal, the command refuses with the shell's message and removes nothing.
func TestHostNothingRemovedWithoutConfirmation(t *testing.T) {
	root := devzoneDir(t)
	runner := folderRunner(t, root)
	code, _, errOut := runUninstall(t, runner, root, nil, "")
	if code != 1 || !strings.Contains(errOut, "✖ Cannot confirm without a terminal: CONFIRM=yes make desinstaller") {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	for _, c := range dockerCalls(runner) {
		if strings.HasPrefix(c, "rm ") || strings.HasPrefix(c, "rmi ") || strings.HasPrefix(c, "volume rm") || strings.HasPrefix(c, "network rm") {
			t.Fatalf("removal call %q without confirmation", c)
		}
	}
}

// TestHostConfirmedByEnvironment: CONFIRM=yes removes without --yes.
func TestHostConfirmedByEnvironment(t *testing.T) {
	root := devzoneDir(t)
	t.Setenv("CONFIRM", "yes")
	runner := folderRunner(t, root)
	code, _, errOut := runUninstall(t, runner, root, nil, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if indexOf(dockerCalls(runner), "rm -f c1") < 0 {
		t.Fatalf("container not removed with CONFIRM=yes: %v", dockerCalls(runner))
	}
}

// TestHostFailureKeepsStateFiles: a failed removal is reported and the state files
// stay, so that a second run can finish the job.
func TestHostFailureKeepsStateFiles(t *testing.T) {
	root := devzoneDir(t, "postgres=on")
	runner := folderRunner(t, root)
	runner.OnError("docker", []string{"rm", "-f", "c1"}, exec.Result{Stderr: []byte("device busy")}, errors.New("exit 1"))
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 1 || !strings.Contains(errOut, "✖ container c1: device busy") {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("state file removed after a failure: %v", err)
	}
	if indexOf(dockerCalls(runner), "rm -f l1") < 0 {
		t.Fatal("the other removals did not go on after a failure")
	}
}

// TestHostNothingToRemove: nothing on the host, nothing in the cluster: the
// command says so, removes the state files and exits 0.
func TestHostNothingToRemove(t *testing.T) {
	root := devzoneDir(t, "postgres=on")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	code, out, errOut := runUninstall(t, runner, root, nil, "")
	if code != 0 || !strings.Contains(out, "✔ Nothing to remove.") {
		t.Fatalf("code = %d, out = %q, err = %q", code, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); !os.IsNotExist(err) {
		t.Fatalf("state file kept with nothing to remove: %v", err)
	}
}

// TestHostInsideContainerDoesNotInventory: inside the pod, docker reaches the host
// Docker: the folder's resources are not looked at, and the command says so.
func TestHostInsideContainerDoesNotInventory(t *testing.T) {
	root := devzoneDir(t)
	t.Setenv("DEVZONE_IN_CONTAINER", "yes")
	runner := folderRunner(t, root)
	code, out, _ := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(out, "make desinstaller on your machine") {
		t.Fatalf("no pod notice:\n%s", out)
	}
	for _, c := range runner.Calls() {
		if c.Name == "npx" || (c.Name == "docker" && len(c.Args) > 0 && c.Args[0] != "info") {
			t.Fatalf("host call inside the container: %s %v", c.Name, c.Args)
		}
	}
}

// TestHostUnreadableConfigurationStops: when the devcontainer configuration cannot
// be read through npx, nothing is removed and the command fails.
func TestHostUnreadableConfigurationStops(t *testing.T) {
	root := devzoneDir(t)
	runner := fake.New()
	runner.On("docker", []string{"info"}, exec.Result{})
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 1 || !strings.Contains(errOut, "cannot read .devcontainer/devcontainer.json (npx @devcontainers/cli)") {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
}

// TestHostKindNetworkKeptWhenInUse: the kind network is removed only when no
// container is attached to it.
func TestHostKindNetworkKeptWhenInUse(t *testing.T) {
	root := devzoneDir(t)
	runner := folderRunner(t, root)
	runner.On("docker", []string{"network", "inspect", "kind"}, exec.Result{Stdout: []byte(`[{"Containers": {"abc": {}}}]`)})
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if indexOf(dockerCalls(runner), "network rm kind") >= 0 {
		t.Fatal("kind network removed while a container is attached")
	}
}
