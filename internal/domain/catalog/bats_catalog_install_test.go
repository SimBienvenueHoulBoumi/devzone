package catalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// programInstall prepares the fake calls of a direct chart installation.
func (f *fixture) programInstall(claim string) {
	f.contextReady()
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{Code: 1})
	f.on([]string{"get", "secret", "mysql-admin"}, fexec.Result{Code: 1})
	f.r.On(f.script, []string{"mysql", "claim", "devzone-mysql"}, fexec.Result{Stdout: []byte(claim + "\n")})
	f.r.On(f.script, []string{"argocd", "catalog-active", "mysql"}, fexec.Result{Code: 1})
	sets := joinedFlags("image=mysql:8.4", "port=3306", "memory=1Gi", "size=5Gi", "claim="+claim)
	f.r.On("helm", append([]string{"template", "mysql", f.chart, "-n", "devzone-mysql"}, sets...),
		fexec.Result{Stdout: []byte("kind: StatefulSet\n  image: mysql:8.4\n  storage: 5Gi\n  name: " + claim + "\n")})
	f.on([]string{"rollout", "status", "statefulset/mysql", "--timeout=300s"}, fexec.Result{})
}

// TestApplyInstalls checks the direct path: chart values, secret, relay and
// address, the grouped credentials regenerated through the devzone launcher,
// with the password never written on the output.
func TestApplyInstalls(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programInstall("donnees")
	if code := f.run("apply"); code != 0 {
		t.Fatalf("apply: code %d, output %q, err %q", code, f.out.String(), f.errOut.String())
	}
	if got := f.out.String(); !strings.Contains(got, "127.0.0.1:3306") || strings.Contains(got, "mdpcatalogue") {
		t.Fatalf("apply output = %q", got)
	}
	calls := f.r.Calls()
	assertCall(t, calls, f.script, "passwords", "regenerate")
	assertCall(t, calls, "kubectl", append([]string{"--context", "devzone", "-n", "devzone-mysql"},
		"create", "secret", "generic", "mysql-admin", "--from-file=password="+filepath.Join(f.root, "workspace", ".mysql", "admin-password"))...)
	assertCall(t, calls, "helm", append([]string{"template", "mysql", f.chart, "-n", "devzone-mysql"},
		joinedFlags("image=mysql:8.4", "port=3306", "memory=1Gi", "size=5Gi", "claim=donnees")...)...)
	if len(f.launches) != 1 || f.launches[0].target != "svc/mysql" || len(f.launches[0].ports) != 1 || f.launches[0].ports[0] != "3306:3306" {
		t.Fatalf("relay launches = %+v", f.launches)
	}
	password := filepath.Join(f.root, "workspace", ".mysql", "admin-password")
	info, err := os.Stat(password)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("password mode = %v, want 600", info.Mode().Perm())
	}
}

// TestApplyReusesPVC checks that a PVC chosen by the MySQL module is passed to
// the chart instead of the default one.
func TestApplyReusesPVC(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programInstall("data")
	if code := f.run("apply"); code != 0 {
		t.Fatalf("apply: code %d", code)
	}
	assertCall(t, f.r.Calls(), "helm", append([]string{"template", "mysql", f.chart, "-n", "devzone-mysql"},
		joinedFlags("image=mysql:8.4", "port=3306", "memory=1Gi", "size=5Gi", "claim=data")...)...)
}

// TestApplyRefusesTwoPVCs checks that an ambiguous volume choice stops the
// installation before helm runs, with the list and the command to choose.
func TestApplyRefusesTwoPVCs(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.contextReady()
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{Code: 1})
	f.r.On(f.script, []string{"mysql", "claim", "devzone-mysql"}, fexec.Result{
		Code: 2,
		Stdout: []byte("devzone : catalog mysql : several volumes found:\n  data-mysql-0\n  donnees-mysql-0\n" +
			"devzone : catalog mysql : choose one with devzone mysql volume <name>\n"),
	})
	if code := f.run("apply"); code == 0 {
		t.Fatal("apply: code 0, want a refusal")
	}
	for _, want := range []string{"data-mysql-0", "donnees-mysql-0", "devzone mysql volume"} {
		if !strings.Contains(f.errOut.String(), want) {
			t.Fatalf("stderr %q misses %s", f.errOut.String(), want)
		}
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm ran after an ambiguous claim: %s", formatCall(call))
		}
	}
}

// TestApplyAlreadyPresent checks that an installed app keeps its chart and
// gets its relay restarted.
func TestApplyAlreadyPresent(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programAdminContext()
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{})
	f.on([]string{"get", "statefulset", "mysql", "-o", "jsonpath={.status.readyReplicas}"},
		fexec.Result{Stdout: []byte("1\n")})
	f.on([]string{"get", "secret", "mysql-admin"}, fexec.Result{})
	if code := f.run("apply"); code != 0 {
		t.Fatalf("apply: code %d", code)
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm reinstalled a present app: %s", formatCall(call))
		}
	}
	if len(f.launches) != 1 {
		t.Fatalf("relay launches = %+v, want one", f.launches)
	}
}

// TestApplyNoCluster checks the refusal and the failure marker without a
// chosen services cluster.
func TestApplyNoCluster(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=on")
	if code := f.run("apply"); code == 0 {
		t.Fatal("apply: code 0, want a refusal")
	}
	if !strings.Contains(f.errOut.String(), "no cluster chosen") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if _, err := os.Stat(f.statePath + "-failed-mysql"); err != nil {
		t.Fatalf("failure marker: %v", err)
	}
}

// TestApplyFailureShowsInSummary checks the failure marker and the ✖ line.
func TestApplyFailureShowsInSummary(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.contextReady()
	f.programAdminContext()
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.on([]string{"get", "secret", "mysql-admin"}, fexec.Result{Code: 1})
	f.r.On(f.script, []string{"mysql", "claim", "devzone-mysql"}, fexec.Result{Stdout: []byte("donnees\n")})
	f.r.On(f.script, []string{"argocd", "catalog-active", "mysql"}, fexec.Result{Code: 1})
	f.r.On("helm", nil, fexec.Result{Code: 1, Stderr: []byte("chart failed\nlast line\n")})
	if code := f.run("apply"); code == 0 {
		t.Fatal("apply: code 0, want a failure")
	}
	marker, err := os.ReadFile(f.statePath + "-failed-mysql")
	if err != nil {
		t.Fatal(err)
	}
	if string(marker) != "last line\n" {
		t.Fatalf("failure marker = %q, want last line", marker)
	}
	f.out.Reset()
	if code := f.run("resume"); code != 0 {
		t.Fatalf("resume: code %d", code)
	}
	if got := f.out.String(); !strings.Contains(got, "✖ application mysql failed") || !strings.Contains(got, "devzone apply") {
		t.Fatalf("resume output = %q", got)
	}
}

// TestApplyUnknownRevisionFails checks that a catalog application is not
// installed directly when Argo CD is on without a usable revision. The exact
// call list proves that no namespace, secret or chart step was attempted.
func TestApplyUnknownRevisionFails(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.contextReady()
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{Code: 1})
	f.r.On(f.script, []string{"mysql", "claim", "devzone-mysql"}, fexec.Result{Stdout: []byte("donnees\n")})
	f.r.On(f.script, []string{"argocd", "catalog-active", "mysql"}, fexec.Result{
		Code: 2, Stderr: []byte("no published tag contains charts/devzone-mysql\n"),
	})
	if code := f.run("apply"); code == 0 {
		t.Fatalf("apply: code 0, want a failure (output %q)", f.out.String())
	}
	if !strings.Contains(f.errOut.String(), "no published tag") {
		t.Fatalf("the reason was not reported: %q", f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" || call.Name == "openssl" {
			t.Fatalf("installation continued after the revision failure: %v", f.r.Calls())
		}
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "create secret") {
			t.Fatalf("a secret was created after the revision failure: %v", f.r.Calls())
		}
	}
}
