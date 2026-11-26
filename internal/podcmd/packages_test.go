package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/packages"
)

// TestHandlesPackages checks that the pod command is registered, not delegated.
func TestHandlesPackages(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := Run([]string{"handles", "packages"}, &out, &errOut); code != 0 {
		t.Fatalf("handles: code %d", code)
	}
}

// packageInstaller is a fake injected into the packages command tests.
type packageInstaller struct {
	available map[string]bool
	installed map[string]bool
	installs  []string
}

// Installed reports the recorded state of a package.
func (i *packageInstaller) Installed(name string) bool { return i.installed[name] }

// Available reports whether the fake index knows the package.
func (i *packageInstaller) Available(name string) bool { return i.available[name] }

// Update does nothing: no index is refreshed by a test.
func (i *packageInstaller) Update() error { return nil }

// Install records the names and marks them installed.
func (i *packageInstaller) Install(names []string) error {
	i.installs = append(i.installs, names...)
	for _, name := range names {
		i.installed[name] = true
	}
	return nil
}

// Remove records a removal by dropping the names from the installed set.
func (i *packageInstaller) Remove(names []string) error {
	for _, name := range names {
		delete(i.installed, name)
	}
	return nil
}

// usePackagesFixture injects a fake installer into the packages command.
func usePackagesFixture(t *testing.T) (*packageInstaller, string) {
	t.Helper()
	dir := t.TempDir()
	installer := &packageInstaller{available: map[string]bool{"tree": true}, installed: map[string]bool{}}
	previous := newPackagesEnvironment
	newPackagesEnvironment = func(ctx *cli.Context) *packages.Env {
		return &packages.Env{
			List:   filepath.Join(dir, ".devzone.packages"),
			Marker: filepath.Join(dir, "failed"), Updated: filepath.Join(dir, "updated"),
			Installer: installer, Now: func() time.Time { return time.Unix(1000000, 0) },
			Out: ctx.Out, Err: ctx.Err,
		}
	}
	t.Cleanup(func() { newPackagesEnvironment = previous })
	return installer, dir
}

// TestPackagesCommandFlow checks add, list, apply and remove through the
// registered command, with no real installation tool.
func TestPackagesCommandFlow(t *testing.T) {
	installer, dir := usePackagesFixture(t)
	for _, args := range [][]string{
		{"packages", "add", "tree"},
		{"packages"},
		{"packages", "list"},
		{"packages", "apply"},
		{"packages", "remove", "tree"},
	} {
		var out, errOut bytes.Buffer
		if code := Run(args, &out, &errOut); code != 0 {
			t.Fatalf("%v: code %d, err %q", args, code, errOut.String())
		}
		if strings.Contains(errOut.String(), "deprecated") {
			t.Fatalf("%v: deprecation warning", args)
		}
	}
	data, err := os.ReadFile(filepath.Join(dir, ".devzone.packages"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(data), "\n") || strings.Count(string(data), "#") != 1 {
		t.Fatalf("list = %q", data)
	}
	if len(installer.installs) != 1 || installer.installs[0] != "tree" {
		t.Fatalf("installs = %v", installer.installs)
	}
}

// TestPackagesRefusals fixes the exit status and messages of an unknown
// command and of an unknown package name.
func TestPackagesRefusals(t *testing.T) {
	_, _ = usePackagesFixture(t)
	var out, errOut bytes.Buffer
	if code := Run([]string{"packages", "wrong"}, &out, &errOut); code != 1 ||
		!strings.Contains(errOut.String(), "unknown command") {
		t.Fatalf("unknown command: code %d, err %q", code, errOut.String())
	}
	errOut.Reset()
	if code := Run([]string{"packages", "add", "nosuchpkg"}, &out, &errOut); code != 1 ||
		!strings.Contains(errOut.String(), "unknown package") {
		t.Fatalf("unknown package: code %d, err %q", code, errOut.String())
	}
}

// TestPackagesApplyMarksFailure checks that a package that cannot be installed
// is written to the failure marker read by the devzone summary.
func TestPackagesApplyMarksFailure(t *testing.T) {
	_, dir := usePackagesFixture(t)
	if err := os.WriteFile(filepath.Join(dir, ".devzone.packages"),
		[]byte("# paquets ajoutés par devzone packages add ; réinstallés à chaque création du conteneur\nghost\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	previous := newPackagesEnvironment
	newPackagesEnvironment = func(ctx *cli.Context) *packages.Env {
		env := &packages.Env{
			List: filepath.Join(dir, ".devzone.packages"), Marker: filepath.Join(dir, "failed"),
			Updated: filepath.Join(dir, "updated"), Now: func() time.Time { return time.Unix(1000000, 0) },
			Out: ctx.Out, Err: ctx.Err,
		}
		env.Installer = failingInstaller{}
		return env
	}
	t.Cleanup(func() { newPackagesEnvironment = previous })
	var out, errOut bytes.Buffer
	if code := Run([]string{"packages", "apply"}, &out, &errOut); code != 1 {
		t.Fatalf("code %d", code)
	}
	data, err := os.ReadFile(filepath.Join(dir, "failed"))
	if err != nil || string(data) != "ghost\n" {
		t.Fatalf("marker = %q, %v", data, err)
	}
}

// failingInstaller reports every package as missing and every install as a no-op.
type failingInstaller struct{}

// Installed always reports a missing package.
func (failingInstaller) Installed(string) bool { return false }

// Available always reports a known package.
func (failingInstaller) Available(string) bool { return true }

// Update is a no-op.
func (failingInstaller) Update() error { return nil }

// Install does nothing, so the package stays missing.
func (failingInstaller) Install([]string) error { return nil }

// Remove is a no-op.
func (failingInstaller) Remove([]string) error { return nil }

// TestHelpListsPackages checks both command listings of the workstation and
// the pod for the packages command.
func TestHelpListsPackages(t *testing.T) {
	for _, file := range []string{"../../.devcontainer/help.sh", "../../README.md"} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "devzone packages") {
			t.Fatalf("%s misses the packages command", file)
		}
	}
}

// TestPackagesWithoutRoot refuses to write outside a devzone folder.
func TestPackagesWithoutRoot(t *testing.T) {
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	previous := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	defer func() { defaultScript = previous }()
	var out, errOut bytes.Buffer
	if code := Run([]string{"packages"}, &out, &errOut); code != 1 {
		t.Fatalf("code %d", code)
	}
}
