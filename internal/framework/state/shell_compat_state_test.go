package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestShellRecoveryGoEquivalent checks frozen recovery marker results: codes,
// no output, integer marker, recent/old age, pending and confirm, taken from
// the shell comparison before state.sh was removed.
func TestShellRecoveryGoEquivalent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state")
	writeStateFile(t, path, "ai=on\n")
	s := At(path)

	if err := s.RecoveryMark(); err != nil { // state_recovery_mark: code 0, no output
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	marker, err := os.ReadFile(path + ".recouvre")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := strconv.ParseInt(strings.TrimSpace(string(marker)), 10, 64); err != nil {
		t.Fatalf("marker %q: %v", marker, err)
	}
	if !s.RecoveryWait() { // state_recovery_wait recent: code 0
		t.Fatal("wait recent: want frozen code 0")
	}
	if !s.RecoveryPending() { // state_recovery_pending: code 0
		t.Fatal("pending: want frozen code 0")
	}

	old := strconv.FormatInt(time.Now().Add(-120*time.Second).Unix(), 10)
	writeStateFile(t, path+".recouvre", old)
	if s.RecoveryWait() { // state_recovery_wait old: code 1
		t.Fatal("wait old: want frozen code 1")
	}

	if err := s.RecoveryConfirm(); err != nil { // state_recovery_confirm: code 0
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	if _, err := os.Stat(path + ".recouvre"); !os.IsNotExist(err) {
		t.Fatalf("marker remains (%v)", err)
	}
}

// TestShellInitGoEquivalent checks frozen creation, restore, rebuild and
// migration results with a fake kubectl (never a real cluster), taken from the
// shell comparison before state.sh was removed.
func TestShellInitGoEquivalent(t *testing.T) {
	modules := defaultModules()
	cases := []struct {
		name      string
		prev      string
		fauxNS    []string
		wantState string
		wantPrev  string
		hasPrev   bool
		wantWarns []string
	}{
		{name: "first install", wantState: "ai=off\nkubernetes=off\ngitlab=off\n"},
		{name: "restore backup", prev: "ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n",
			wantState: "ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n", wantPrev: "ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n", hasPrev: true,
			wantWarns: []string{"devzone : state restored from the backup copy: <STATE> (confirm with devzone apply)"}},
		{name: "rebuild namespaces", fauxNS: []string{"devzone-postgres", "devzone-gitlab"},
			wantState: "ai=off\nkubernetes=off\ngitlab=on\npostgres=on\nargocd=off\nmysql=off\ncluster=docker-desktop\n",
			wantWarns: []string{"devzone : state rebuilt from the namespaces of the services cluster: <STATE> (confirm with devzone apply)"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "state")
			home := filepath.Join(dir, "home")
			if err := os.MkdirAll(home, 0o755); err != nil {
				t.Fatal(err)
			}
			if tc.prev != "" {
				writeStateFile(t, path+".prev", tc.prev)
			}
			t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(dir, "host.config"))
			var warns []string
			if err := At(path).Init(modules, fakeKubectlInit(tc.fauxNS), home, nil, func(m string) { warns = append(warns, m) }); err != nil {
				t.Fatalf("code 1, want frozen code 0: %v", err)
			}
			assertFile(t, path, tc.wantState)
			assertPrev(t, path+".prev", tc.hasPrev, tc.wantPrev)
			gotWarns := normalizeState(strings.Join(warns, "\n"), path)
			if strings.Join(tc.wantWarns, "\n") != gotWarns {
				t.Fatalf("warnings %q, want %q", gotWarns, strings.Join(tc.wantWarns, "\n"))
			}
		})
	}
}

// TestShellAbortGoEquivalent checks frozen abort results: failed write leaves
// the state unchanged, no temporary file and no lock (code 1), taken from the
// shell comparison before state.sh was removed.
func TestShellAbortGoEquivalent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state")
	writeStateFile(t, path, "ai=on\n")
	if err := os.Mkdir(path+".prev", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := At(path).Set("ai", "off"); err == nil {
		t.Fatal("code 0, want frozen code 1 when the backup path is a directory")
	}
	assertFile(t, path, "ai=on\n")
	if _, err := os.Stat(path + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("lockdir remains (%v)", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".devzone.modules.") {
			t.Fatalf("temporary file remains: %s", e.Name())
		}
	}
}

// TestShellHostContextGoEquivalent checks frozen host context output for a
// services cluster, using only a fake kubectl, taken from the shell comparison
// before state.sh was removed.
func TestShellHostContextGoEquivalent(t *testing.T) {
	kube := fakeKubectlFunc(nil, func(joined string) (string, bool) {
		if strings.Contains(joined, "config get-contexts -o name") {
			return "devzone\ndocker-desktop\n", true
		}
		if strings.Contains(joined, "docker-desktop") {
			return "docker-desktop\n", true
		}
		return "", false
	})
	if got := hostContextOfCluster(kube, "docker-desktop"); got != "docker-desktop" {
		t.Fatalf("host context %q, want frozen %q", got, "docker-desktop")
	}
}

// fakeKubectlInit returns a fake kubectl runner like the shell fake used by
// the former comparison, never a real cluster.
func fakeKubectlInit(fauxNS []string) Runner {
	return fakeKubectlFunc(fauxNS, func(joined string) (string, bool) {
		if strings.Contains(joined, "config view") {
			for _, c := range []string{"devzone", "docker-desktop"} {
				if strings.Contains(joined, c) {
					return "docker-desktop\n", true
				}
			}
			return "", false
		}
		if strings.Contains(joined, "config get-contexts -o name") {
			return "devzone\ndocker-desktop\n", true
		}
		return "", false
	})
}

// fakeKubectlFunc adapts kubectl calls (including env KUBECONFIG ... kubectl)
// to a pure Go runner; extra answers kubectl always emits are added first.
func fakeKubectlFunc(fauxNS []string, extra func(joined string) (string, bool)) Runner {
	return func(name string, args ...string) (string, string, error) {
		kargs := args
		if name == "env" {
			kargs = nil
			for _, a := range args {
				if a == "kubectl" || strings.HasPrefix(a, "KUBECONFIG=") {
					continue
				}
				kargs = append(kargs, a)
			}
		} else if name != "kubectl" {
			return "", "", fmt.Errorf("not kubectl: %s", name)
		}
		joined := strings.Join(kargs, " ")
		if len(kargs) >= 2 && kargs[0] == "get" && kargs[1] == "namespaces" {
			out := ""
			for _, n := range fauxNS {
				out += "namespace/" + n + "\n"
			}
			return out, "", nil
		}
		if out, ok := extra(joined); ok {
			return out, "", nil
		}
		return "", "", fmt.Errorf("exit 1")
	}
}

// normalizeState replaces the temporary state path with <STATE>.
func normalizeState(s, path string) string { return strings.ReplaceAll(s, path, "<STATE>") }
