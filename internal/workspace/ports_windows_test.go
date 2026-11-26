//go:build windows

package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestWindowsWatcherRound relays the services of the modules file on Windows
// with a fake kubectl and a fake process starter: no relay, cluster or watcher
// is really started. It then removes the state of ports no longer wanted.
func TestWindowsWatcherRound(t *testing.T) {
	dir := t.TempDir()
	modules := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(modules, []byte("postgres=on\ngitlab=on\nargocd=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", filepath.Join(dir, "state"))
	t.Setenv("DEVZONE_INSTANCE", "devzone")
	t.Setenv("DEVZONE_ARGOCD_PORT", "8443")
	runner := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "devzone\n"},
		{match: "", stdout: ""},
	}}
	var started []string
	pid := os.Getpid() + 10000
	start := func(cmd *exec.Cmd) (int, error) {
		started = append(started, strings.Join(cmd.Args, " "))
		pid++
		return pid, nil
	}
	var out, errOut bytes.Buffer
	env := roundEnv{runner: runner, dir: portsDir(), modules: modules, taken: func(int) bool { return false },
		start: start, max: appsMax, out: &out, errOut: &errOut}
	env.round()
	for _, port := range []string{"5432", "8929", "2224"} {
		data, err := os.ReadFile(filepath.Join(env.dir, "relays", port))
		if err != nil {
			t.Fatalf("relay %s not recorded: %v", port, err)
		}
		if _, err := strconv.Atoi(strings.TrimSpace(string(data))); err != nil {
			t.Fatalf("relay %s holds %q, want a pid: %v", port, data, err)
		}
	}
	if got := strings.Count(out.String(), " relayed on 127.0.0.1\n"); got != 3 {
		t.Fatalf("%d relay lines, want 3: %q", got, out.String())
	}
	if !strings.Contains(strings.Join(started, "\n"), "--namespace devzone-gitlab port-forward --address 127.0.0.1 svc/gitlab-gitlab-shell 2224:2224") {
		t.Fatalf("the GitLab SSH relay is missing from %q", started)
	}
	if errOut.Len() != 0 {
		t.Fatalf("unexpected warnings: %q", errOut.String())
	}
	if err := os.WriteFile(modules, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	env.round()
	for _, sub := range []string{"relays", "taken"} {
		entries, err := os.ReadDir(filepath.Join(env.dir, sub))
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) != 0 {
			t.Fatalf("%s still holds %d entries after the ports disappeared", sub, len(entries))
		}
	}
}

// TestWindowsWatcherStatus checks that the Windows status reads the same state
// files and reports a live watcher with the process primitives of this platform.
func TestWindowsWatcherStatus(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	t.Setenv("DEVZONE_PORTS_AGENT_DIR", filepath.Join(dir, "agents"))
	pid := os.Getpid()
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "relays"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "relays", "3000"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "taken"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "taken", "4000"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if status := PortsStatus(&out); status != 0 {
		t.Fatalf("PortsStatus status = %d", status)
	}
	want := "Port watcher: running (pid " + strconv.Itoa(pid) + ")\n" +
		"Port watcher automatic start: disabled\n" +
		"  127.0.0.1:3000 relayed\n" +
		"  ⚠ port 4000 already in use on the workstation, not relayed\n"
	if out.String() != want {
		t.Fatalf("status = %q, want %q", out.String(), want)
	}
}
