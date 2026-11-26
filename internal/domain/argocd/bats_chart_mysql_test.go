package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// writeMySQLConf installs the MySQL application values in the temporary code
// tree so chart parameter tests read the same file as the shell library.
func writeMySQLConf(t *testing.T, f *modFixture) {
	t.Helper()
	dir := filepath.Join(f.root, ".devcontainer", "catalog", "mysql")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(dir, "app.conf"), "image=mysql:8.4\nport=3306\nmemoire=1Gi\ntaille=5Gi\n")
}

// TestBatsServicesChartMySQLClaim mirrors the one-volume bats test: the chart
// parameters hold the values of app.conf and the single existing claim.
func TestBatsServicesChartMySQLClaim(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeMySQLConf(t, f)
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-mysql", "get", "pvc", "-o", `jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}`), fexec.Result{Stdout: []byte("donnees-mysql-0\n")})
	params, code := newFixtureModule(t, f).servicesChartMySQL()
	if code != 0 || strings.Join(params, " ") != "image=mysql:8.4 port=3306 memory=1Gi size=5Gi claim=donnees" {
		t.Fatalf("code=%d params=%v err=%q", code, params, f.err.String())
	}
}

// TestBatsServicesChartMySQLDefaults mirrors the no-volume bats test: the
// chart defaults are used when no persistent volume claim exists.
func TestBatsServicesChartMySQLDefaults(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeMySQLConf(t, f)
	params, code := newFixtureModule(t, f).servicesChartMySQL()
	if code != 0 || strings.Join(params, " ") != "image=mysql:8.4 port=3306 memory=1Gi size=5Gi" {
		t.Fatalf("code=%d params=%v err=%q", code, params, f.err.String())
	}
}

// TestBatsServicesChartMySQLSeveralVolumes mirrors the several-volumes bats
// test: the chart is refused with code 2 before any parameter is produced.
func TestBatsServicesChartMySQLSeveralVolumes(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeMySQLConf(t, f)
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-mysql", "get", "pvc", "-o", `jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}`), fexec.Result{Stdout: []byte("a-mysql-0\nb-mysql-0\n")})
	params, code := newFixtureModule(t, f).servicesChartMySQL()
	if code != 2 || len(params) != 0 || !strings.Contains(f.err.String(), "several MySQL volumes") {
		t.Fatalf("code=%d params=%v err=%q", code, params, f.err.String())
	}
}
