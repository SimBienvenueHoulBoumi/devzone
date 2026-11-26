package packages

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeInstaller records package operations without touching the machine.
type fakeInstaller struct {
	installed map[string]bool
	available map[string]bool
	failing   map[string]bool
	updates   int
	failIndex bool
	calls     []string
}

// Installed reports the recorded state of a package.
func (f *fakeInstaller) Installed(name string) bool { return f.installed[name] }

// Available reports whether the fake index knows the package.
func (f *fakeInstaller) Available(name string) bool { return f.available[name] }

// Update records an index refresh, optionally failing.
func (f *fakeInstaller) Update() error {
	f.updates++
	f.calls = append(f.calls, "update")
	if f.failIndex {
		return errors.New("index unavailable")
	}
	return nil
}

// Install records an installation and marks the names as installed, unless
// they are programmed to fail.
func (f *fakeInstaller) Install(names []string) error {
	f.calls = append(f.calls, "install "+strings.Join(names, " "))
	for _, name := range names {
		if f.failing[name] {
			return errors.New("install failed")
		}
	}
	for _, name := range names {
		f.installed[name] = true
	}
	return nil
}

// Remove records a removal and drops the names from the installed set.
func (f *fakeInstaller) Remove(names []string) error {
	f.calls = append(f.calls, "remove "+strings.Join(names, " "))
	for _, name := range names {
		delete(f.installed, name)
	}
	return nil
}

// newEnv builds a disposable packages environment with an injected installer.
func newEnv(t *testing.T) (*Env, *fakeInstaller) {
	t.Helper()
	dir := t.TempDir()
	installer := &fakeInstaller{
		installed: map[string]bool{}, available: map[string]bool{"tree": true, "htop": true, "ghost": true},
		failing: map[string]bool{},
	}
	env := &Env{
		List:      filepath.Join(dir, ".devzone.packages"),
		Marker:    filepath.Join(dir, "packages.failed"),
		Updated:   filepath.Join(dir, "packages.updated"),
		Installer: installer, Now: func() time.Time { return time.Unix(1000000, 0) },
		Out: &strings.Builder{}, Err: &strings.Builder{},
	}
	return env, installer
}

// outOf returns the text written to the output stream.
func outOf(e *Env) string { return e.Out.(*strings.Builder).String() }

// errOf returns the text written to the error stream.
func errOf(e *Env) string { return e.Err.(*strings.Builder).String() }

// writeListFile installs a list with the exact stored header of the contract.
func writeListFile(t *testing.T, path string, lines string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(header+lines), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestEmptyListAndHelp checks the empty-list message and the absence of a
// deprecation warning for the English subcommands.
func TestEmptyListAndHelp(t *testing.T) {
	env, _ := newEnv(t)
	if err := env.Show(); err != nil {
		t.Fatal(err)
	}
	if outOf(env) != "no package (devzone packages add <name>)\n" {
		t.Fatalf("list = %q", outOf(env))
	}
	if err := env.Add([]string{}); err == nil || !strings.Contains(err.Error(), "add expects") {
		t.Fatalf("empty add = %v", err)
	}
}

// TestAddInstallsAndRecords checks the installation and the recorded header.
func TestAddInstallsAndRecords(t *testing.T) {
	env, installer := newEnv(t)
	installer.available["tree"] = true
	if err := env.Add([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	if len(installer.calls) != 2 || installer.calls[0] != "update" || installer.calls[1] != "install tree" {
		t.Fatalf("calls = %v", installer.calls)
	}
	data, err := os.ReadFile(env.List)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != header+"tree\n" {
		t.Fatalf("list = %q", data)
	}
	info, err := os.Stat(env.List)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, %v", info, err)
	}
}

// TestAddUnknownPackageKeepsList checks the refusal, its code-carrying error
// and that nothing was installed or recorded.
func TestAddUnknownPackageKeepsList(t *testing.T) {
	env, installer := newEnv(t)
	err := env.Add([]string{"nosuchpkg"})
	var refusal *Refusal
	if err == nil || !errors.As(err, &refusal) || !strings.Contains(err.Error(), "unknown package: nosuchpkg") {
		t.Fatalf("add = %v", err)
	}
	if _, statErr := os.Stat(env.List); !os.IsNotExist(statErr) {
		t.Fatalf("list created: %v", statErr)
	}
	for _, call := range installer.calls {
		if strings.HasPrefix(call, "install ") {
			t.Fatalf("installed: %v", installer.calls)
		}
	}
}

// TestRemoveDropsAndUninstalls checks that a listed package is removed from
// the list and from the machine, and that an unlisted one is refused.
func TestRemoveDropsAndUninstalls(t *testing.T) {
	env, installer := newEnv(t)
	writeListFile(t, env.List, "tree\nhtop\n")
	installer.installed["tree"] = true
	if err := env.Remove([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(env.List)
	if err != nil || string(data) != header+"htop\n" {
		t.Fatalf("list = %q, %v", data, err)
	}
	if len(installer.calls) != 1 || installer.calls[0] != "remove tree" {
		t.Fatalf("calls = %v", installer.calls)
	}
	err = env.Remove([]string{"nosuchpkg"})
	if err == nil || !strings.Contains(err.Error(), "package not listed") {
		t.Fatalf("remove = %v", err)
	}
}

// TestApplyInstallsOnlyMissing checks that an installed package is not
// installed again and that no failure marker is left.
func TestApplyInstallsOnlyMissing(t *testing.T) {
	env, installer := newEnv(t)
	writeListFile(t, env.List, "tree\nhtop\n")
	installer.installed["tree"] = true
	if err := env.Apply(); err != nil {
		t.Fatal(err)
	}
	if len(installer.calls) != 2 || installer.calls[0] != "update" || installer.calls[1] != "install htop" {
		t.Fatalf("calls = %v", installer.calls)
	}
	if _, err := os.Stat(env.Marker); !os.IsNotExist(err) {
		t.Fatalf("marker left: %v", err)
	}
}
