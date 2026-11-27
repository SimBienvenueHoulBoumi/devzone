package command

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// egressTestRunner answers the cluster calls of an egress command: the
// Application is returned only when asked, and the proxy is ready at once.
type egressTestRunner struct{ application string }

// Kubectl gives the Application fields and lets every proxy probe succeed.
func (r egressTestRunner) Kubectl(args []string, _ io.Reader, out, _ io.Writer) (int, error) {
	if r.application != "" && strings.Contains(strings.Join(args, " "), "get application.argoproj.io") {
		_, _ = io.WriteString(out, r.application)
	}
	return 0, nil
}

// Helm succeeds: egress never renders the chart itself.
func (egressTestRunner) Helm(_ []string, _ io.Reader, _, _ io.Writer) (int, error) {
	return 0, nil
}

// stubEgress replaces the collaborators of egress for one test.
func stubEgress(t *testing.T, application string) {
	t.Helper()
	runner, look, sleep, deploy := egressRunner, egressLookPath, egressSleep, egressDeploy
	t.Cleanup(func() {
		egressRunner, egressLookPath, egressSleep, egressDeploy = runner, look, sleep, deploy
	})
	egressRunner = egressTestRunner{application: application}
	egressLookPath = func(string) (string, error) { return "/bin/true", nil }
	egressSleep = func(time.Duration) {}
	egressDeploy = func(*cli.Context, string, string, string) int { return 0 }
}

// TestEgressParamsCommandPrintsChartParameters checks the internal word that
// start and update replay, with no newline as the shell command substitution.
func TestEgressParamsCommandPrintsChartParameters(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "egress=strict\negress_domains=api.example.com\n")
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"egress", "params"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, stderr = %q", code, errOut.String())
	}
	want := "egressProxy.enabled=true egressProxy.mode=strict egressProxy.extraDomains=api.example.com"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

// TestEgressCommandSetsMode checks that a mode is written after the cluster
// check and kept without an Application, as the shell did.
func TestEgressCommandSetsMode(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "egress=observation\n")
	stubEgress(t, "")
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"egress", "strict"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, stderr = %q", code, errOut.String())
	}
	if got := readModulesKeyForTest(t, "egress"); got != "strict" {
		t.Fatalf("egress = %q, want strict", got)
	}
	if !strings.Contains(out.String(), "✔ egress strict") || !strings.Contains(out.String(), "no Argo CD Application") {
		t.Fatalf("stdout = %q", out.String())
	}
}

// TestEgressCommandDeploysRunningImage checks that a change redeploys the
// workspace at the revision and tag of its Application.
func TestEgressCommandDeploysRunningImage(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "egress=strict\negress_domains=api.example.com\n")
	stubEgress(t, "v0.1.0 0.1.0")
	var deployed []string
	egressDeploy = func(_ *cli.Context, repository, tag, revision string) int {
		deployed = []string{repository, tag, revision}
		return 0
	}
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"egress", "allow", "cdn.example.com"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, stderr = %q", code, errOut.String())
	}
	if strings.Join(deployed, " ") != "ghcr.io/simbienvenuehoulboumi/devzone-workspace 0.1.0 v0.1.0" {
		t.Fatalf("deploy = %v", deployed)
	}
	if got := readModulesKeyForTest(t, "egress_domains"); got != "api.example.com,cdn.example.com" {
		t.Fatalf("egress_domains = %q", got)
	}
}

// TestEgressCommandRefusesUnknownWord checks the status and the message of an
// unknown argument.
func TestEgressCommandRefusesUnknownWord(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "egress=off\n")
	stubEgress(t, "")
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"egress", "maybe"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 1 {
		t.Fatalf("status = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "unknown egress argument: maybe") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}

// readModulesKeyForTest reads a key of the modules file of the test folder.
func readModulesKeyForTest(t *testing.T, key string) string {
	t.Helper()
	data, err := os.ReadFile(".devzone.modules")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if value, ok := strings.CutPrefix(line, key+"="); ok {
			return value
		}
	}
	return ""
}
