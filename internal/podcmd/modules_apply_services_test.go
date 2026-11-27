package podcmd

import (
	"strings"
	"testing"
)

// TestEnablePostgresMismatchContext checks that a --context different from the
// saved cluster is refused with the cluster hint and disables the module (#280).
func TestEnablePostgresMismatchContext(t *testing.T) {
	f := newModuleFixture(t, "cluster=kind-devzone")
	f.pod.outs["kube saved"] = "kind-devzone"
	if code := f.m.applyPostgres("on", []string{"--context", "host-cluster"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone cluster host-cluster") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if !strings.Contains(f.state(t), "postgres=off") {
		t.Fatalf("state = %q", f.state(t))
	}
}

// TestEnablePostgresUnknownArgument checks the refusal of an unknown argument.
func TestEnablePostgresUnknownArgument(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	if code := f.m.applyPostgres("on", []string{"--bogus"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	want := "devzone : unknown argument: --bogus (devzone enable postgres --context CTX [--confirm CTX])\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestEnablePostgresContextWithoutValue checks that --context without its value is refused.
func TestEnablePostgresContextWithoutValue(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	if code := f.m.applyPostgres("on", []string{"--context"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : context expects a context") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestApplyPostgresRestartsRelay checks that a stopped relay is restarted
// without reinstalling PostgreSQL (orchestration of the shell).
func TestApplyPostgresRestartsRelay(t *testing.T) {
	f := newModuleFixture(t, "postgres=on", "cluster=kind-devzone")
	f.pod.outs["postgres status"] = "ready on kind-devzone, relay stopped: devzone apply\n"
	f.pod.outs["kube saved"] = "kind-devzone\n"
	f.pod.outs["kube choose "] = "kind-devzone\n"
	if code := f.m.applyPostgres("on", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	want := []string{"kube saved", "kube choose ", "kube save kind-devzone", "postgres status", "postgres relay-start"}
	if strings.Join(f.pod.calls, "|") != strings.Join(want, "|") {
		t.Fatalf("calls = %v, want %v", f.pod.calls, want)
	}
	if !strings.Contains(f.out.String(), "devzone : postgres : relay restarted") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyPostgresInstallFailure checks the failure marker and the status 1 of a failed install.
func TestApplyPostgresInstallFailure(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.pod.codes["postgres install"] = 1
	f.pod.outs["postgres status"] = "absent\n"
	if code := f.m.applyPostgres("on", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if f.marker("postgres") != "postgres\n" {
		t.Fatalf("marker = %q", f.marker("postgres"))
	}
}

// TestApplyPostgresOffUninstalls checks the removal and the cleared marker.
func TestApplyPostgresOffUninstalls(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	f.m.setMarker("postgres")
	if code := f.m.applyPostgres("off", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("postgres uninstall") || f.marker("postgres") != "" {
		t.Fatalf("calls %v, marker %q", f.pod.calls, f.marker("postgres"))
	}
}

// TestMysqlWithoutClusterRefused checks that mysql needs a saved cluster, with its failure marker.
func TestMysqlWithoutClusterRefused(t *testing.T) {
	f := newModuleFixture(t, "mysql=on")
	if code := f.m.applyMysql("on"); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : mysql: no cluster chosen: devzone enable mysql") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if f.marker("mysql") != "mysql\n" || !strings.Contains(f.state(t), "mysql=off") {
		t.Fatalf("marker %q, state %q", f.marker("mysql"), f.state(t))
	}
}

// TestMysqlOffKeepsVolume checks that a removal without --yes keeps the databases.
func TestMysqlOffKeepsVolume(t *testing.T) {
	f := newModuleFixture(t, "mysql=on")
	if code := f.m.applyMysql("off"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("catalog remove mysql") || f.pod.has("mysql delete-data --yes") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	f.m.deleteData = true
	if code := f.m.applyMysql("off"); code != 0 || !f.pod.has("mysql delete-data --yes") {
		t.Fatalf("with data: code %d, calls %v", code, f.pod.calls)
	}
}

// TestApplyGitlabReadyRunnerOnline checks that an active gitlab is only
// reconnected to the hosts, without the installer.
func TestApplyGitlabReadyRunnerOnline(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "ready, runner online\n"
	f.m.setMarker("gitlab")
	if code := f.m.applyGitlab("on"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.pod.has("gitlab install") || !f.pod.has("gitlab host-set") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	// failure of an old run cleared: gitlab is ready (#366)
	if f.marker("gitlab") != "" {
		t.Fatalf("marker kept: %q", f.marker("gitlab"))
	}
	if !strings.Contains(f.out.String(), "devzone : gitlab already active, nothing to do.") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyGitlabReadyWithoutRunnerInstalls checks that a ready gitlab without
// a runner online goes through the installer, and clears the marker of an old failure.
func TestApplyGitlabReadyWithoutRunnerInstalls(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "ready, no runner\n"
	f.m.setMarker("gitlab")
	if code := f.m.applyGitlab("on"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("gitlab install") || f.pod.has("gitlab host-set") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	if f.marker("gitlab") != "" {
		t.Fatalf("marker kept: %q", f.marker("gitlab"))
	}
}

// TestApplyGitlabInstallFailure checks that a failed installer leaves the marker of gitlab.
func TestApplyGitlabInstallFailure(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "absent\n"
	f.pod.codes["gitlab install"] = 1
	if code := f.m.applyGitlab("on"); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if f.marker("gitlab") != "gitlab\n" {
		t.Fatalf("marker = %q", f.marker("gitlab"))
	}
}

// TestApplyGitlabOff checks the removal: with --yes the data goes too, and a
// missing namespace only says so.
func TestApplyGitlabOff(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.m.deleteData = true
	if code := f.m.applyGitlab("off"); code != 0 || !f.pod.has("gitlab uninstall --yes") {
		t.Fatalf("code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "gitlab=on")
	f.pod.codes["gitlab installed"] = 1
	if code := f.m.applyGitlab("off"); code != 0 || f.pod.has("gitlab uninstall") {
		t.Fatalf("not installed: code %d, calls %v", code, f.pod.calls)
	}
	if !strings.Contains(f.out.String(), "gitlab already deactivated") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}
