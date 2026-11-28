package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// initFixture holds a disposable home, state and versions file; every external
// program goes through a fake runner, so no git, npm or repowarden is executed.
type initFixture struct {
	t         *testing.T
	root      string
	home      string
	bashrc    string
	versions  string
	runner    *fake.Runner
	out       strings.Builder
	ctx       *cli.Context
	pinned    string
	applyCode int
	applyRuns int
}

// newInitFixture builds a hermetic pod initialization context with all four
// steps ready to succeed on the first run.
func newInitFixture(t *testing.T) *initFixture {
	t.Helper()
	f := &initFixture{t: t, root: t.TempDir(), pinned: "4.18.2"}
	f.home = filepath.Join(f.root, "home")
	f.bashrc = filepath.Join(f.home, ".bashrc")
	dev := filepath.Join(f.root, ".devcontainer")
	f.versions = filepath.Join(dev, "versions.env")
	if err := os.MkdirAll(f.home, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dev, 0o755); err != nil {
		t.Fatal(err)
	}
	f.write(f.versions, "REPOWARDEN_VERSION="+f.pinned+"\n")
	f.write(filepath.Join(dev, "devzone"), "")
	f.write(filepath.Join(f.root, ".devzone.modules"),
		"ai=off\nkubernetes=off\ngitlab=off\npostgres=off\nmysql=off\nargocd=off\n")
	t.Setenv("HOME", f.home)
	t.Setenv(devcontainerDirOverride, dev)
	t.Setenv("DEVZONE_POD_SCRIPT", filepath.Join(dev, "devzone"))
	t.Setenv("DEVZONE_ROOT", f.root)
	t.Setenv("DEVZONE_STATE", filepath.Join(f.root, ".devzone.modules"))
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("DEVZONE_SERVICES_ADMIN", "")
	f.runner = fake.New()
	f.runner.On("git", []string{"config", "--global", "--get-all", "safe.directory"}, exec.Result{})
	f.runner.On("git", []string{"config", "--global", "--add", "safe.directory", safeDirectory}, exec.Result{})
	f.runner.On("repowarden", []string{"--version"}, exec.Result{Stdout: []byte("0.0.0\n")})
	f.runner.On("npm", []string{"install", "-g", "repowarden@" + f.pinned}, exec.Result{})
	f.runner.On("repowarden", []string{"install", "--global", "--lang", "fr"}, exec.Result{})
	f.ctx = &cli.Context{Out: &f.out, Err: &f.out, Stdin: strings.NewReader(""), Runner: f.runner}
	previous := applyInitModules
	t.Cleanup(func() { applyInitModules = previous })
	applyInitModules = func(ctx *cli.Context) int {
		f.applyRuns++
		if f.applyCode != 0 {
			return f.applyCode
		}
		return newModules(ctx).apply()
	}
	return f
}

// write creates a fixture file with the given content.
func (f *initFixture) write(path, content string) {
	f.t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// read returns the content of a fixture file.
func (f *initFixture) read(path string) string {
	f.t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		f.t.Fatal(err)
	}
	return string(data)
}

// run performs the init command with the fixture's fake runner.
func (f *initFixture) run() int {
	f.t.Helper()
	return runInit(f.ctx)
}

// hasLogLine reports whether the exact journal line was written.
func (f *initFixture) hasLogLine(line string) bool {
	for _, got := range strings.Split(strings.TrimRight(f.out.String(), "\n"), "\n") {
		if got == "devzone init: "+line {
			return true
		}
	}
	return false
}

// called reports whether the fake runner received the exact program and args.
func (f *initFixture) called(name string, args ...string) bool {
	for _, call := range f.runner.Calls() {
		if call.Name == name && strings.Join(call.Args, "\x00") == strings.Join(args, "\x00") {
			return true
		}
	}
	return false
}
