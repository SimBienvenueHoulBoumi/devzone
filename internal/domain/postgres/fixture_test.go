package postgres

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// sequenceRunner generates a new password at each call, like the fake openssl
// of postgres.bats, and delegates every other command to the fake runner.
type sequenceRunner struct {
	*fake.Runner
	passwords int
}

// Run implements exec.Runner.
func (s *sequenceRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if name == "openssl" {
		s.passwords++
		return exec.Result{Stdout: []byte("pwsecret" + strconv.Itoa(s.passwords) + "\n")}, nil
	}
	return s.Runner.Run(ctx, name, args, opts)
}

// launchCall records one requested relay.
type launchCall struct {
	name, ctxName, ns, target string
	ports                     []string
}

// fixture holds the fake runner, the isolated root and the output of one test.
type fixture struct {
	t         *testing.T
	r         *sequenceRunner
	root      string
	statePath string
	codeRoot  string
	out       strings.Builder
	errOut    strings.Builder
	launches  []launchCall
	opts      Options
}

// newFixture creates a devzone root with a fake runner and a fake password
// library, like the setup of postgres.bats.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "home")
	codeRoot := filepath.Join(root, "code")
	if err := os.MkdirAll(codeRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "charts", "devzone-postgres"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "charts", "devzone-postgres", "Chart.yaml"), []byte("name: devzone-postgres\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(codeRoot, "password.sh"), []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(root, ".devzone.modules")
	t.Setenv("HOME", home)
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", statePath)
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(root, "absent-host.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(home, ".kube", "config"))
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("DEVZONE_INSTANCE", "")
	// The shell run by some tests (the devzone summary) must never reach the
	// cluster of the machine: fake kubectl, kind and helm (no cluster), a fake
	// devzone (Go commands it calls) and a kubeconfig inside the temporary home.
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"kubectl": "#!/usr/bin/env bash\nexit 1\n",
		"kind":    "#!/usr/bin/env bash\nexit 0\n",
		"helm":    "#!/usr/bin/env bash\nexit 1\n",
		"devzone": "#!/usr/bin/env bash\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("KUBECONFIG", filepath.Join(home, ".kube", "config"))
	base := fake.New()
	base.On("kubectl", nil, exec.Result{})
	base.On("kind", nil, exec.Result{})
	base.On("helm", nil, exec.Result{})
	base.On("bash", nil, exec.Result{})
	base.On("jq", nil, exec.Result{Stdout: []byte(`{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}` + "\n")})
	f := &fixture{t: t, r: &sequenceRunner{Runner: base}, root: root, statePath: statePath, codeRoot: codeRoot}
	f.opts = Options{
		Runner:    f.r,
		Out:       &f.out,
		Err:       &f.errOut,
		Root:      root,
		CodeRoot:  codeRoot,
		StatePath: statePath,
		Stdin:     strings.NewReader(""),
		Launcher: func(dir, name, ctxName, namespace, target string, ports []string) (int, error) {
			f.launches = append(f.launches, launchCall{name, ctxName, namespace, target, ports})
			return 999999, nil
		},
	}
	return f
}

// saveState writes the lines of .devzone.modules used by the tests.
func (f *fixture) saveState(lines ...string) {
	f.t.Helper()
	if err := os.WriteFile(f.statePath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// activeOn saves a chosen cluster and marks the module as installed.
func (f *fixture) activeOn(ctxName string) {
	f.saveState("postgres=on", "cluster="+ctxName)
	f.onAdmin(ctxName, []string{"get", "namespace", ns}, exec.Result{})
}

// on programs a kubectl call on the devzone context.
func (f *fixture) on(args []string, res exec.Result) {
	f.r.On("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...), res)
}

// onRaw programs a kubectl call with the exact arguments given.
func (f *fixture) onRaw(args []string, res exec.Result) { f.r.On("kubectl", args, res) }

// adminArgs builds the arguments of an administrator kubectl call.
func (f *fixture) adminArgs(ctxName string, args []string) []string {
	conf := filepath.Join(f.root, "home", ".kube", "config")
	return append([]string{"--kubeconfig=" + conf, "--context", ctxName}, args...)
}

// onAdmin programs an administrator kubectl call.
func (f *fixture) onAdmin(ctxName string, args []string, res exec.Result) {
	f.r.On("kubectl", f.adminArgs(ctxName, args), res)
}

// contextReady programs the config queries of devzone_context_set.
func (f *fixture) contextReady(ctxName, cluster, user string) {
	clusterQuery := fmt.Sprintf(`{.contexts[?(@.name==%q)].context.cluster}`, ctxName)
	userQuery := fmt.Sprintf(`{.contexts[?(@.name==%q)].context.user}`, ctxName)
	f.onRaw([]string{"config", "view", "-o", clusterQuery}, exec.Result{Stdout: []byte(cluster + "\n")})
	f.onRaw([]string{"config", "view", "-o", userQuery}, exec.Result{Stdout: []byte(user + "\n")})
	f.onRaw([]string{"config", "set-context", "devzone", "--cluster=" + cluster, "--user=" + user}, exec.Result{})
}

// programChart programs the helm template and upgrade responses for postgres.
func (f *fixture) programChart(size string) {
	manifest := "kind: StatefulSet\n  image: postgres:16\n  storage: " + size + "\n"
	args := []string{"template", "postgres", filepath.Join(filepath.Dir(f.codeRoot), "charts", "devzone-postgres"), "-n", ns, "--set", "size=" + size}
	f.r.On("helm", args, exec.Result{Stdout: []byte(manifest)})
	f.r.On("helm", []string{"--kube-context", "devzone", "upgrade", "--install", "postgres",
		filepath.Join(filepath.Dir(f.codeRoot), "charts", "devzone-postgres"), "-n", ns, "--set", "size=" + size}, exec.Result{})
}

// assertCall fails when calls does not contain name with the exact arguments.
func assertCall(t *testing.T, calls []fake.Call, name string, args []string) {
	t.Helper()
	for _, call := range calls {
		if call.Name != name || strings.Join(call.Args, "\x00") != strings.Join(args, "\x00") {
			continue
		}
		return
	}
	t.Fatalf("missing call %s %v in %+v", name, args, calls)
}

// relayLauncher records the relays and returns a dead PID (no process needed).
func relayLauncher(f *fixture) relay.Launcher { return f.opts.Launcher }
