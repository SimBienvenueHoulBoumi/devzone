package packages

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestSystemInstallerCommands checks that the real installer only calls the
// injected runner and keeps the dpkg-query, apt-cache and apt-get arguments.
func TestSystemInstallerCommands(t *testing.T) {
	runner := fake.New()
	runner.On("dpkg-query", nil, fexec.Result{Stdout: []byte("install ok installed\n")})
	runner.On("apt-cache", []string{"show", "tree"}, fexec.Result{})
	runner.On("sudo", nil, fexec.Result{})
	installer := &SystemInstaller{
		Runner: runner, Sudo: "sudo", Apt: "apt-get", AptCache: "apt-cache", DpkgQuery: "dpkg-query",
	}
	if !installer.Installed("tree") || !installer.Available("tree") {
		t.Fatalf("state not read: %v", runner.Calls())
	}
	if err := installer.Update(); err != nil {
		t.Fatal(err)
	}
	if err := installer.Install([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	if err := installer.Remove([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	calls := runner.Calls()
	want := []string{
		"dpkg-query -W -f=${Status} tree",
		"apt-cache show tree",
		"sudo apt-get update",
		"sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tree",
		"sudo apt-get remove -y tree",
	}
	if len(calls) != len(want) {
		t.Fatalf("calls = %v", calls)
	}
	for i, call := range calls {
		if got := call.Name + " " + strings.Join(call.Args, " "); got != want[i] {
			t.Fatalf("call %d = %q, want %q", i, got, want[i])
		}
	}
}

// TestSystemInstallerWithoutSudo checks the no-elevation branch: the tool
// stays the program name and the non-interactive marker goes to the environment.
func TestSystemInstallerWithoutSudo(t *testing.T) {
	runner := fake.New()
	runner.On("apt-get", nil, fexec.Result{})
	installer := &SystemInstaller{Runner: runner, Apt: "apt-get", AptCache: "apt-cache", DpkgQuery: "dpkg-query"}
	if err := installer.Install([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	calls := runner.Calls()
	if len(calls) != 1 || calls[0].Name != "apt-get" ||
		strings.Join(calls[0].Args, " ") != "install -y --no-install-recommends tree" {
		t.Fatalf("calls = %v", calls)
	}
	if len(calls[0].Opts.Env) != 1 || calls[0].Opts.Env[0] != "DEBIAN_FRONTEND=noninteractive" {
		t.Fatalf("env = %v", calls[0].Opts.Env)
	}
}

// TestSystemInstallerFailures checks that a non-zero exit status is reported
// as an error without exposing the output of the tool.
func TestSystemInstallerFailures(t *testing.T) {
	runner := fake.New()
	runner.On("sudo", nil, fexec.Result{Code: 1, Stderr: []byte("secret-tool-output")})
	installer := &SystemInstaller{Runner: runner, Sudo: "sudo", Apt: "apt-get"}
	err := installer.Install([]string{"tree"})
	if err == nil {
		t.Fatal("expected a failure")
	}
	if strings.Contains(err.Error(), "secret-tool-output") {
		t.Fatalf("tool output leaked: %q", err)
	}
}

// TestSystemFromEnvironment fixes the overridable tool names, including an
// explicitly empty sudo which disables elevation.
func TestSystemFromEnvironment(t *testing.T) {
	t.Setenv("DEVZONE_PACKAGES_SUDO", "")
	t.Setenv("DEVZONE_PACKAGES_APT", "fake-apt")
	t.Setenv("DEVZONE_PACKAGES_APTCACHE", "fake-cache")
	t.Setenv("DEVZONE_PACKAGES_DPKG_QUERY", "fake-query")
	installer := SystemFromEnvironment(fake.New())
	if installer.Sudo != "" || installer.Apt != "fake-apt" ||
		installer.AptCache != "fake-cache" || installer.DpkgQuery != "fake-query" {
		t.Fatalf("installer = %+v", installer)
	}
	t.Setenv("DEVZONE_PACKAGES_SUDO", "fake-sudo")
	if got := SystemFromEnvironment(fake.New()).Sudo; got != "fake-sudo" {
		t.Fatalf("sudo = %q", got)
	}
}
