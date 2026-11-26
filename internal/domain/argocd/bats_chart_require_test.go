package argocd

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestBatsChartRequireCorrect mirrors the passing chart-require bats test: a
// chart named after its service is accepted without any command.
func TestBatsChartRequireCorrect(t *testing.T) {
	f := newModFixture(t)
	writeChart(t, f.root, "postgres", "devzone-postgres")
	if code := newFixtureModule(t, f).chartRequire("postgres"); code != 0 || f.err.String() != "" {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
}

// TestBatsChartRequireMisnamedOrAbsent mirrors the refusal bats test: a wrong
// chart name or a missing Chart.yaml is refused with code 2.
func TestBatsChartRequireMisnamedOrAbsent(t *testing.T) {
	f := newModFixture(t)
	m := newFixtureModule(t, f)
	writeChart(t, f.root, "postgres", "pg")
	if code := m.chartRequire("postgres"); code != 2 || !strings.Contains(f.err.String(), "✖ postgres : chart charts/devzone-postgres missing or misnamed") {
		t.Fatalf("misnamed: code=%d err=%q", code, f.err.String())
	}
	if code := m.chartRequire("argocd"); code != 2 || !strings.Contains(f.err.String(), "✖ argocd : chart charts/devzone-argocd missing or misnamed") {
		t.Fatalf("absent: code=%d err=%q", code, f.err.String())
	}
}

// TestBatsServicesReconcileMisnamedChart mirrors the reconcile bats test: a
// misnamed chart applies nothing for that service, the other one goes on.
func TestBatsServicesReconcileMisnamedChart(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeChart(t, f.root, "postgres", "pg")
	writeChart(t, f.root, "mysql", "devzone-mysql")
	writeTestFile(t, filepath.Join(f.root, "package.json"), "{\"version\": \"1.2.3\"}\n")
	writeTestFile(t, filepath.Join(f.root, ".argocd.conf"), "[services]\npostgres=on\nmysql=on\n")
	if code := newFixtureModule(t, f).servicesReconcile(); code != 2 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(joinedArgs(call), "devzone-postgres") {
			t.Fatalf("misnamed chart applied: %q", joinedArgs(call))
		}
	}
	if findStdinCall(t, f.r.Calls(), "kubectl", "name: devzone-mysql", devzoneKubectl("apply", "-f", "-")...) < 0 {
		t.Fatalf("other service not applied: %v", f.r.Calls())
	}
}

// TestBatsServicesApplicationApplyMisnamedChart mirrors the Application bats
// test: a misnamed chart declares no Application and runs no command.
func TestBatsServicesApplicationApplyMisnamedChart(t *testing.T) {
	f := newModFixture(t)
	writeChart(t, f.root, "postgres", "pg")
	if code := newFixtureModule(t, f).servicesApplicationApply("postgres"); code != 2 {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls=%v", f.r.Calls())
	}
}

// TestBatsServicesReconcileCorrectCharts mirrors the passing reconcile bats
// test: namespace, secret and Application are applied in that order.
func TestBatsServicesReconcileCorrectCharts(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeChart(t, f.root, "postgres", "devzone-postgres")
	writeTestFile(t, filepath.Join(f.root, "package.json"), "{\"version\": \"1.2.3\"}\n")
	writeTestFile(t, filepath.Join(f.root, ".argocd.conf"), "[services]\npostgres=on\n")
	if code := newFixtureModule(t, f).servicesReconcile(); code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	calls := f.r.Calls()
	namespace := callIndex(calls, "kubectl", devzoneKubectl("apply", "-f", "-")...)
	secret := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-postgres", "create", "secret", "generic", "postgres-admin", "--from-file=password="+filepath.Join(f.root, "workspace", ".postgres", "admin-password"))...)
	app := findStdinCall(t, calls, "kubectl", "kind: Application", devzoneKubectl("apply", "-f", "-")...)
	if namespace < 0 || secret < 0 || app < 0 || !(namespace < secret && secret < app) {
		t.Fatalf("unexpected reconcile order: %v", calls)
	}
}

// TestBatsCatalogueApplyMisnamedChart mirrors the catalogue-apply bats test:
// the chart check refuses before any Application is applied.
func TestBatsCatalogueApplyMisnamedChart(t *testing.T) {
	f := newModFixture(t)
	writeChart(t, f.root, "postgres", "pg")
	code := f.run("catalogue-apply", "postgres", "devzone-postgres", "postgres:16", "5432", "256Mi", "5Gi")
	if code != 2 || !strings.Contains(f.err.String(), "✖ postgres : chart charts/devzone-postgres missing or misnamed") {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls=%v", f.r.Calls())
	}
}

// TestBatsInstallChartRequireAbsent mirrors the install chart bats test: an
// absent Argo CD chart is refused by the shared chart check before any command.
func TestBatsInstallChartRequireAbsent(t *testing.T) {
	f := newModFixture(t)
	code := f.run("chart-require", "argocd")
	if code != 2 || !strings.Contains(f.err.String(), "✖ argocd : chart charts/devzone-argocd missing or misnamed") {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls=%v", f.r.Calls())
	}
}
