package postgres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestRelayStartStop checks that the relay is started only once, with the same
// port-forward arguments as the shell, and that relay-stop removes its PID.
func TestRelayStartStop(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	pid := livePID(t)
	f.launches = nil
	f.opts.Launcher = func(dir, name, ctxName, namespace, target string, ports []string) (int, error) {
		f.launches = append(f.launches, launchCall{name, ctxName, namespace, target, ports})
		return pid, nil
	}
	for i := 0; i < 2; i++ {
		if code := Run(nil, f.opts, []string{"relay-start"}); code != 0 {
			t.Fatalf("relay-start: code %d", code)
		}
	}
	if len(f.launches) != 1 {
		t.Fatalf("relay started %d times, want 1", len(f.launches))
	}
	want := launchCall{"postgres", "host-cluster", ns, "svc/postgres", []string{"5432:5432"}}
	if f.launches[0].name != want.name || f.launches[0].ctxName != want.ctxName ||
		f.launches[0].target != want.target || strings.Join(f.launches[0].ports, ",") != "5432:5432" {
		t.Fatalf("relay = %+v, want %+v", f.launches[0], want)
	}
	pidPath := filepath.Join(f.root, "workspace", ".postgres", "relais.pid")
	if _, err := os.Stat(pidPath); err != nil {
		t.Fatalf("PID file: %v", err)
	}
	Run(nil, f.opts, []string{"relay-stop"})
	if _, err := os.Stat(pidPath); !os.IsNotExist(err) {
		t.Fatalf("PID file still present: %v", err)
	}
}

// TestAuthorize checks the isolating NetworkPolicy sent on stdin and the
// access message, with the missing namespace refusal.
func TestAuthorize(t *testing.T) {
	f := newFixture(t)
	if code := Run(nil, f.opts, []string{"authorize"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "devzone postgres: namespace missing") {
		t.Fatalf("authorize: code %d, stderr %q", code, f.errOut.String())
	}
	f.errOut.Reset()
	if code := Run(nil, f.opts, []string{"authorize", "mon-app"}); code != 0 {
		t.Fatalf("authorize: code %d, stderr %q", code, f.errOut.String())
	}
	found := false
	for _, call := range f.r.Calls() {
		if strings.Join(call.Args, " ") == "--context devzone -n mon-app apply -f -" {
			found = true
			if !strings.Contains(stdinOf(t, call), "name: devzone-meme-namespace") {
				t.Fatalf("manifest = %q", stdinOf(t, call))
			}
		}
	}
	if !found {
		t.Fatalf("NetworkPolicy not applied: %+v", f.r.Calls())
	}
	if f.out.String() != "devzone postgres: access allowed from mon-app to the PostgreSQL service\n" {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestForbid checks the jq-built patch and the failure and success messages.
func TestForbid(t *testing.T) {
	f := newFixture(t)
	if code := Run(nil, f.opts, []string{"forbid"}); code != 2 {
		t.Fatalf("forbid: code %d", code)
	}
	f.errOut.Reset()
	f.r.On("kubectl", []string{"--context", "devzone", "-n", ns, "patch", "networkpolicy",
		"devzone-meme-namespace", "-p", `{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}`}, exec.Result{})
	if code := Run(nil, f.opts, []string{"forbid", "mon-app"}); code != 0 {
		t.Fatalf("forbid: code %d, stderr %q", code, f.errOut.String())
	}
	if f.out.String() != "devzone postgres: access forbidden from mon-app to the PostgreSQL service\n" {
		t.Fatalf("output = %q", f.out.String())
	}
	f.out.Reset()
	f.errOut.Reset()
	f.r.On("kubectl", []string{"--context", "devzone", "-n", ns, "patch", "networkpolicy",
		"devzone-meme-namespace", "-p", `{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}`},
		exec.Result{Code: 1, Stderr: []byte("forbidden\n")})
	if code := Run(nil, f.opts, []string{"forbid", "mon-app"}); code != 1 ||
		!strings.Contains(f.errOut.String(), "cannot remove the access rule of mon-app: forbidden") {
		t.Fatalf("forbid failure: code %d, stderr %q", code, f.errOut.String())
	}
}

// TestNoDeprecatedWarning checks that English subcommand names never emit the
// deprecation warning checked at the end of postgres.bats.
func TestNoDeprecatedWarning(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	for _, args := range [][]string{{"create", "taskmanager", "--new-password"}, {"list"}, {"delete", "taskmanager", "--yes"}} {
		f.errOut.Reset()
		if code := Run(nil, f.opts, args); code != 0 {
			t.Fatalf("%v: code %d, stderr %q", args, code, f.errOut.String())
		}
		if strings.Contains(f.errOut.String(), "deprecated") {
			t.Fatalf("%v: warning %q", args, f.errOut.String())
		}
	}
}
