package mysql

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// sequenceRunner generates a new password at each call, like the fake openssl
// of mysql.bats, and delegates every other command to the fake runner.
type sequenceRunner struct {
	*fake.Runner
	passwords int
}

// Run implements exec.Runner.
func (s *sequenceRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if name == "openssl" {
		s.passwords++
		return exec.Result{Stdout: []byte("mdpmysql" + strconv.Itoa(s.passwords) + "\n")}, nil
	}
	return s.Runner.Run(ctx, name, args, opts)
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

// launchCall records one requested relay.
type launchCall struct {
	name, ctxName, ns, target string
	ports                     []string
}

// newFixture creates a devzone root with a fake runner and a fake password
// library, like the setup of mysql.bats.
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
	if err := os.MkdirAll(filepath.Join(root, "charts", "devzone-mysql"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "charts", "devzone-mysql", "Chart.yaml"), []byte("name: devzone-mysql\n"), 0o644); err != nil {
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
	base := fake.New()
	base.On("kubectl", nil, exec.Result{})
	base.On("helm", nil, exec.Result{})
	base.On("bash", nil, exec.Result{})
	f := &fixture{t: t, r: &sequenceRunner{Runner: base}, root: root, statePath: statePath, codeRoot: codeRoot}
	f.opts = Options{
		Runner:    f.r,
		Out:       &f.out,
		Err:       &f.errOut,
		Stdin:     strings.NewReader(""),
		Root:      root,
		CodeRoot:  codeRoot,
		StatePath: statePath,
		Sleep:     func(time.Duration) {},
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
	f.saveState("mysql=on", "cluster="+ctxName)
	f.onAdmin(ctxName, []string{"get", "namespace", ns}, exec.Result{})
}

// on programs a kubectl call on the devzone context.
func (f *fixture) on(args []string, res exec.Result) {
	f.r.On("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...), res)
}

// onNs programs a kubectl call on the devzone context in an arbitrary namespace.
func (f *fixture) onNs(namespace string, args []string, res exec.Result) {
	f.r.On("kubectl", append([]string{"--context", "devzone", "-n", namespace}, args...), res)
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

// programChart programs the helm template and upgrade responses for mysql.
func (f *fixture) programChart(claim string) {
	manifest := "kind: StatefulSet\n  name: " + claim + "\n  storage: 5Gi\n"
	sets := []string{"image=mysql:8.4", "port=3306", "memory=1Gi", "size=5Gi", "claim=" + claim}
	chart := filepath.Join(filepath.Dir(f.codeRoot), "charts", "devzone-mysql")
	f.r.On("helm", append([]string{"template", "mysql", chart, "-n", ns}, flags(sets)...), exec.Result{Stdout: []byte(manifest)})
	f.r.On("helm", append([]string{"--kube-context", "devzone", "upgrade", "--install", "mysql", chart, "-n", ns}, flags(sets)...), exec.Result{})
}

// flags turns chart values into helm --set arguments.
func flags(sets []string) []string {
	out := make([]string, 0, len(sets)*2)
	for _, set := range sets {
		out = append(out, "--set", set)
	}
	return out
}

// noSecret programs a missing mysql-admin secret so install creates one.
func (f *fixture) noSecret() {
	f.on([]string{"get", "secret", "mysql-admin"}, exec.Result{Code: 1})
}

// rootReady programs the mysql-admin secret with the given root password.
func (f *fixture) rootReady(password string) {
	encoded := base64Encode(password)
	f.on([]string{"get", "secret", "mysql-admin"}, exec.Result{})
	f.on([]string{"get", "secret", "mysql-admin", "-o", "jsonpath={.data.password}"},
		exec.Result{Stdout: []byte(encoded)})
	dir := filepath.Join(f.root, "workspace", ".mysql")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "admin-password"), []byte(password), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// base64Encode encodes a secret value as Kubernetes stores it.
func base64Encode(value string) string { return base64.StdEncoding.EncodeToString([]byte(value)) }

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
