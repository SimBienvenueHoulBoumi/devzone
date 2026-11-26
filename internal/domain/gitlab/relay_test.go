package gitlab

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// putPid writes a live relay pid of the fixture (the fake ProcessAlive knows
// only this pid), so a test never signals a real process.
func (f *fixture) putPid(name, pid string) {
	dir := filepath.Join(f.root, "workspace", "."+name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.tb.Fatal(err)
	}
	if err := os.WriteFile(dir+"/relais.pid", []byte(pid+"\n"), 0o644); err != nil {
		f.tb.Fatal(err)
	}
	f.alivePid = pid
}

// TestRelayStart checks the port-forwards of the two relays: the namespace
// services, not the old cluster node, and no extra tool or network mapping.
func TestRelayStart(t *testing.T) {
	f := newFixture(t)
	if code := f.run("relay-start"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if len(f.relays) != 2 {
		t.Fatalf("relays = %v", f.relays)
	}
	for _, want := range []string{
		"gitlab-web: devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181",
		"gitlab-ssh: devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:2224",
	} {
		found := false
		for _, relay := range f.relays {
			if relay == want {
				found = true
			}
		}
		if !found {
			t.Errorf("relay %q missing from %v", want, f.relays)
		}
	}
	joined := strings.Join(f.relays, "\n")
	for _, gone := range []string{"gitlab-control-plane", "32022", "TCP-LISTEN", "network connect"} {
		if strings.Contains(joined, gone) {
			t.Errorf("relay uses %q: %s", gone, joined)
		}
	}
}

// TestRelayActiveAndStatus checks relay-status with one or two stopped relays.
func TestRelayActiveAndStatus(t *testing.T) {
	f := newFixture(t)
	if code := f.run("relay-status"); code != 1 {
		t.Fatalf("stopped code = %d, want 1", code)
	}
	if f.outStr() != "gitlab relay stopped on 8929 2224\n" {
		t.Fatalf("output = %q", f.outStr())
	}
	f.putPid("gitlab-web", "123456")
	f.out.Reset()
	if code := f.run("relay-status"); code != 1 ||
		f.outStr() != "gitlab relay stopped on 2224\n" {
		t.Fatalf("one relay: code %d, output %q", code, f.outStr())
	}
}

// TestRelayStop checks that relay-stop lists the children, stops both relays
// and removes their pid files (gitlab.bats relay-stop, uninstall).
func TestRelayStop(t *testing.T) {
	f := newFixture(t)
	f.putPid("gitlab-web", "999999")
	f.r.On("pgrep", []string{"-P", "999999"}, exec.Result{Stdout: []byte("1000000\n")})
	f.r.On("pgrep", []string{"-P", "222222"}, exec.Result{})
	f.putPid("gitlab-ssh", "222222")
	if code := f.run("relay-stop"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !f.hasCall("pgrep -P 999999") || !f.hasCall("pgrep -P 222222") {
		t.Errorf("children not listed: %v", f.calls())
	}
	for _, name := range []string{"gitlab-web", "gitlab-ssh"} {
		if _, err := os.Stat(filepath.Join(f.root, "workspace", "."+name, "relais.pid")); !os.IsNotExist(err) {
			t.Errorf("relais.pid of %s still there", name)
		}
	}
}
