package kube

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMetricsVersionMatchesVersionsEnv checks that the Go installer uses the
// metrics-server release declared as METRICS_SERVER_VERSION in versions.env,
// so the workstation installer and the pod cannot drift apart. The pin is
// read from the shipped file, never from a copy kept here.
func TestMetricsVersionMatchesVersionsEnv(t *testing.T) {
	devcontainer := filepath.Join("..", "..", "..", ".devcontainer")
	data, err := os.ReadFile(filepath.Join(devcontainer, "versions.env"))
	if err != nil {
		t.Fatal(err)
	}
	want := ""
	for _, line := range strings.Split(string(data), "\n") {
		if value, ok := strings.CutPrefix(strings.TrimSpace(line), "METRICS_SERVER_VERSION="); ok {
			want = strings.TrimSpace(value)
		}
	}
	if want == "" {
		t.Fatal("METRICS_SERVER_VERSION missing from versions.env")
	}
	if MetricsVersion != want {
		t.Fatalf("MetricsVersion = %q, want %q from versions.env", MetricsVersion, want)
	}
	abs, err := filepath.Abs(filepath.Join(devcontainer, "devzone"))
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_POD_SCRIPT", abs)
	if got := metricsVersion(); got != want {
		t.Fatalf("metricsVersion() = %q, want %q from versions.env", got, want)
	}
}
