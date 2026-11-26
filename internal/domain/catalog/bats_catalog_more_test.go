package catalog

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestSummaryRelayStopped checks that an installed app with no live relay
// proposes devzone repair instead of its address.
func TestSummaryRelayStopped(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programAdminContext()
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{})
	f.on([]string{"get", "statefulset", "mysql", "-o", "jsonpath={.status.readyReplicas}"},
		fexec.Result{Stdout: []byte("1\n")})
	if code := f.run("resume"); code != 0 {
		t.Fatalf("resume: code %d", code)
	}
	got := f.out.String()
	if !strings.Contains(got, "⚠ application mysql") || !strings.Contains(got, "devzone repair") || strings.Contains(got, "✔") {
		t.Fatalf("resume output = %q", got)
	}
}

// TestSummaryInPod checks that the pod uses the cluster DNS and the workspace
// ports address, never a StatefulSet listing.
func TestSummaryInPod(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.r.On("getent", []string{"hosts", "mysql.devzone-mysql.svc"}, fexec.Result{})
	if code := f.run("resume"); code != 0 {
		t.Fatalf("resume: code %d", code)
	}
	if got := f.out.String(); !strings.Contains(got, "installed: local access: devzone workspace ports") {
		t.Fatalf("resume output = %q", got)
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "get statefulset") {
			t.Fatalf("StatefulSet read in the pod: %s", formatCall(call))
		}
	}
}

// TestSummaryInPodAbsent checks that a service that does not resolve is expected.
func TestSummaryInPodAbsent(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.onAdmin([]string{"get", "namespace", "devzone-mysql"}, fexec.Result{Code: 1})
	f.r.On("getent", []string{"hosts", "mysql.devzone-mysql.svc"}, fexec.Result{Code: 2})
	if code := f.run("resume"); code != 0 {
		t.Fatalf("resume: code %d", code)
	}
	if got := f.out.String(); !strings.Contains(got, "expected: devzone apply") {
		t.Fatalf("resume output = %q", got)
	}
}

// TestUnusedMySQLVolume checks the warning of a PVC not mounted by MySQL.
func TestUnusedMySQLVolume(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programAdminContext()
	f.on([]string{"get", "statefulset", "mysql"}, fexec.Result{})
	f.on([]string{"get", "statefulset", "mysql", "-o", "jsonpath={.status.readyReplicas}"},
		fexec.Result{Stdout: []byte("1\n")})
	f.on([]string{"get", "statefulset", "mysql", "-o",
		"jsonpath={.spec.volumeClaimTemplates[0].metadata.name}"}, fexec.Result{Stdout: []byte("data\n")})
	f.on([]string{"get", "pvc", "-o", `jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}`},
		fexec.Result{Stdout: []byte("data-mysql-0\nancien-mysql-0\n")})
	if code := f.run("resume"); code != 0 {
		t.Fatalf("resume: code %d", code)
	}
	got := f.out.String()
	if !strings.Contains(got, "⚠ volume ancien-mysql-0 not used : devzone mysql volume") || strings.Contains(got, "data-mysql-0 not used") {
		t.Fatalf("resume output = %q", got)
	}
}

// TestRemoveKeepsVolume checks that removing an app deletes its objects and
// keeps the volume, as the shell entry point did.
func TestRemoveKeepsVolume(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programAdminContext()
	f.on([]string{"get", "statefulset", "mysql", "-o",
		"jsonpath={.spec.volumeClaimTemplates[0].metadata.name}"}, fexec.Result{Stdout: []byte("data\n")})
	f.r.On(f.script, []string{"argocd", "catalog-application-exists", "mysql"}, fexec.Result{Code: 1})
	if code := f.run("remove", "mysql"); code != 0 {
		t.Fatalf("remove: code %d", code)
	}
	assertCall(t, f.r.Calls(), "kubectl", "--context", "devzone", "-n", "devzone-mysql",
		"delete", "statefulset/mysql", "service/mysql", "secret/mysql-admin")
	if got := f.out.String(); !strings.Contains(got, "✔ mysql removed from the cluster; volume data-mysql-0 and databases kept: devzone mysql volume") {
		t.Fatalf("remove output = %q", got)
	}
}

// TestRemoveArgoCD checks the message of an application removed by Argo CD.
func TestRemoveArgoCD(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.programAdminContext()
	f.r.On(f.script, []string{"argocd", "catalog-application-exists", "mysql"}, fexec.Result{})
	if code := f.run("remove", "mysql"); code != 0 {
		t.Fatalf("remove: code %d", code)
	}
	assertCall(t, f.r.Calls(), f.script, "argocd", "catalog-delete", "mysql")
	if got := f.out.String(); !strings.Contains(got, "Application deleted; volume donnees-mysql-0 and databases kept") {
		t.Fatalf("remove output = %q", got)
	}
}

// TestUsageAndHelp checks the status and the usage line of bad arguments.
func TestUsageAndHelp(t *testing.T) {
	f := newFixture(t)
	if code := f.run("nope"); code != 1 {
		t.Fatalf("unknown: code %d, want 1", code)
	}
	if got := f.errOut.String(); got != usageLine+"\n" {
		t.Fatalf("usage = %q", got)
	}
	f.errOut.Reset()
	if code := f.run("--help"); code != 0 {
		t.Fatalf("help: code %d", code)
	}
	if !strings.Contains(f.out.String(), "Application catalog") {
		t.Fatalf("help output = %q", f.out.String())
	}
}
