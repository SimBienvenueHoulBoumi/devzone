package catalog

import (
	"context"
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

const mysqlConf = "name=mysql\ndescription=Shared MySQL, one database per project\n" +
	"image=mysql:8.4\nport=3306\nmemoire=1Gi\ntaille=5Gi\nnamespace=devzone-mysql\n"

// fixture holds the isolated folders and the fakes of one catalog test.
type fixture struct {
	t         *testing.T
	r         *fake.Runner
	root      string
	home      string
	codeRoot  string
	statePath string
	script    string
	chart     string
	out       strings.Builder
	errOut    strings.Builder
	launches  []relayCall
	opts      Options
}

// relayCall records one requested relay, without starting a process.
type relayCall struct {
	dir, name, ctxName, ns, target string
	ports                          []string
}

// newFixture builds a devzone root, a catalog app and a fake runner, as the
// setup of the removed bats tests did, with no real tool and no real process.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "home")
	code := filepath.Join(root, "code")
	catalogDir := filepath.Join(code, "catalog", "mysql")
	chart := filepath.Join(root, "charts", "devzone-mysql")
	for _, dir := range []string{filepath.Join(home, ".kube"), catalogDir, chart} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(catalogDir, "app.conf"), mysqlConf)
	writeTestFile(t, filepath.Join(chart, "Chart.yaml"), "name: devzone-mysql\n")
	writeTestFile(t, filepath.Join(code, "password.sh"), "#!/usr/bin/env bash\nexit 0\n")
	statePath := filepath.Join(root, ".devzone.modules")
	host := filepath.Join(root, "hote.config")
	writeTestFile(t, host, "")
	t.Setenv("HOME", home)
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", statePath)
	t.Setenv("DEVZONE_KUBE_HOST", host)
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(home, ".kube", "config"))
	t.Setenv("DEVZONE_CATALOG", filepath.Join(code, "catalog"))
	t.Setenv("DEVZONE_CATALOG_WATCHER_DIR", filepath.Join(root, "watcher"))
	t.Setenv("DEVZONE_CATALOG_REAL", "")
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("BATS_TEST_TMPDIR", "")
	for _, key := range []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"} {
		t.Setenv(key, "")
	}
	r := fake.New()
	r.On("kubectl", nil, fexec.Result{})
	r.On("helm", nil, fexec.Result{})
	r.On("bash", nil, fexec.Result{})
	r.On("openssl", nil, fexec.Result{Stdout: []byte("mdpcatalogue\n")})
	r.On("getent", nil, fexec.Result{Code: 2})
	f := &fixture{
		t: t, r: r, root: root, home: home, codeRoot: code, statePath: statePath,
		script: filepath.Join(code, "devzone"), chart: chart,
	}
	f.opts = Options{
		Runner:    r,
		Out:       &f.out,
		Err:       &f.errOut,
		Root:      root,
		CodeRoot:  code,
		StatePath: statePath,
		Sleep:     func(time.Duration) {},
		Step:      time.Nanosecond,
		Launcher: func(dir, name, ctxName, ns, target string, ports []string) (int, error) {
			f.launches = append(f.launches, relayCall{dir, name, ctxName, ns, target, ports})
			return 424242, nil
		},
	}
	return f
}

// writeTestFile writes a text file of a test fixture.
func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// saveState writes the lines of .devzone.modules used by a test.
func (f *fixture) saveState(lines ...string) {
	writeTestFile(f.t, f.statePath, strings.Join(lines, "\n")+"\n")
}

// run executes a catalog command through the fixture and returns its status.
func (f *fixture) run(args ...string) int { return Run(context.Background(), f.opts, args) }

// runWatcher executes a watcher command through the fixture.
func (f *fixture) runWatcher(args ...string) int {
	return WatcherRun(context.Background(), f.opts, args)
}

// on programs a kubectl call on the devzone context in the mysql namespace.
func (f *fixture) on(args []string, res fexec.Result) {
	f.r.On("kubectl", append([]string{"--context", "devzone", "-n", "devzone-mysql"}, args...), res)
}

// onNs programs a kubectl call on the devzone context in another namespace.
func (f *fixture) onNs(ns string, args []string, res fexec.Result) {
	f.r.On("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...), res)
}

// onRaw programs a kubectl call with the exact arguments given.
func (f *fixture) onRaw(args []string, res fexec.Result) { f.r.On("kubectl", args, res) }

// adminArgs builds the arguments of an administrator kubectl call.
func (f *fixture) adminArgs(args []string) []string {
	return append([]string{"--kubeconfig=" + filepath.Join(f.home, ".kube", "config"), "--context", "kind-devzone"}, args...)
}

// onAdmin programs an administrator kubectl call.
func (f *fixture) onAdmin(args []string, res fexec.Result) { f.r.On("kubectl", f.adminArgs(args), res) }

// contextReady programs the config queries of devzone_context_set.
func (f *fixture) contextReady() {
	name := "kind-devzone"
	f.onRaw([]string{"config", "view", "-o", fmt.Sprintf(`{.contexts[?(@.name==%q)].context.cluster}`, name)},
		fexec.Result{Stdout: []byte(name + "\n")})
	f.onRaw([]string{"config", "view", "-o", fmt.Sprintf(`{.contexts[?(@.name==%q)].context.user}`, name)},
		fexec.Result{Stdout: []byte("admin\n")})
	f.onRaw([]string{"config", "set-context", "devzone", "--cluster=" + name, "--user=admin"}, fexec.Result{})
}

// programAdminContext teaches the fake kubectl that the services context is saved.
func (f *fixture) programAdminContext() {
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{})
}

// callIndex returns the position of a recorded call, or minus one.
func callIndex(calls []fake.Call, name string, args ...string) int {
	for i, call := range calls {
		if call.Name != name || len(call.Args) != len(args) {
			continue
		}
		same := true
		for j := range args {
			if call.Args[j] != args[j] {
				same = false
				break
			}
		}
		if same {
			return i
		}
	}
	return -1
}

// hasCall reports whether a command with these exact arguments was recorded.
func hasCall(calls []fake.Call, name string, args ...string) bool {
	return callIndex(calls, name, args...) >= 0
}

// assertCall fails when the command was not recorded.
func assertCall(t *testing.T, calls []fake.Call, name string, args ...string) {
	t.Helper()
	if !hasCall(calls, name, args...) {
		t.Fatalf("missing call %s %v in %+v", name, args, calls)
	}
}

// joinedFlags turns chart values into their helm --set arguments.
func joinedFlags(sets ...string) []string {
	out := make([]string, 0, len(sets)*2)
	for _, set := range sets {
		out = append(out, "--set", set)
	}
	return out
}

// shellRun runs a bash program with positional arguments, for the tests that
// compare a Go behaviour with the real shell library.
func shellRun(t *testing.T, program, stdin string, args ...string) (string, int) {
	t.Helper()
	cmd := osexec.Command("bash", append([]string{"-c", program, "_"}, args...)...)
	cmd.Env = append(os.Environ(), "ETAT="+os.Getenv("DEVZONE_STATE"))
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	exitErr, ok := err.(*osexec.ExitError)
	if !ok {
		t.Fatalf("bash: %v", err)
	}
	return string(out), exitErr.ExitCode()
}

// repoPath returns a path of this checkout, relative to the package folder.
func repoPath(parts ...string) string {
	all := append([]string{"..", "..", ".."}, parts...)
	return filepath.Join(all...)
}

// formatCall renders one recorded call for failure messages.
func formatCall(call fake.Call) string {
	return fmt.Sprintf("%s %s", call.Name, strings.Join(call.Args, " "))
}
