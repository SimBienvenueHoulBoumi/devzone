package command

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// offerRun runs clusterOfferCommand with the answers as standard input and
// returns its status and standard error
func offerRun(t *testing.T, answers string) (int, string) {
	t.Helper()
	var errOut bytes.Buffer
	ctx := &cli.Context{Out: &bytes.Buffer{}, Err: &errOut, Stdin: strings.NewReader(answers), Runner: fake.New()}
	return clusterOfferCommand(ctx), errOut.String()
}

// TestClusterOfferNoTerminal: without a terminal nothing is asked, status 1, silent
func TestClusterOfferNoTerminal(t *testing.T) {
	t.Setenv("DEVZONE_TERMINAL", "")
	code, errOut := offerRun(t, "2\ny\n")
	if code != 1 || errOut != "" {
		t.Fatalf("code = %d, stderr = %q; want 1 and nothing", code, errOut)
	}
}

// TestClusterOfferForcedTerminalEmptyCancels: DEVZONE_TERMINAL forces the menu; an empty answer cancels
func TestClusterOfferForcedTerminalEmptyCancels(t *testing.T) {
	t.Setenv("DEVZONE_TERMINAL", "1")
	code, errOut := offerRun(t, "\n")
	if code != 1 || errOut != "✖ cancelled\n" {
		t.Fatalf("code = %d, stderr = %q; want 1 and the cancel message", code, errOut)
	}
}

// TestClusterOfferNullDeviceIsNotTerminal: the null device is a character device, but not a terminal
func TestClusterOfferNullDeviceIsNotTerminal(t *testing.T) {
	t.Setenv("DEVZONE_TERMINAL", "")
	null, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	var errOut bytes.Buffer
	ctx := &cli.Context{Out: &bytes.Buffer{}, Err: &errOut, Stdin: null, Runner: fake.New()}
	if code := clusterOfferCommand(ctx); code != 1 || errOut.Len() != 0 {
		t.Fatalf("code = %d, stderr = %q; want 1 and nothing", code, errOut.String())
	}
}

// TestClusterOfferCreationRemoteCluster: the creation path through the command
// (the Go equivalent of the bats test "creation through the command"): a remote
// context is picked, its name typed back, and kubectl selects it; the command
// exits 0. The fake runner answers only what is programmed, so nothing real runs.
func TestClusterOfferCreationRemoteCluster(t *testing.T) {
	t.Setenv("DEVZONE_TERMINAL", "1")
	var out, errOut bytes.Buffer
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("docker-desktop\nprod-eks\n")})
	runner.On("kubectl", []string{"config", "view", "--minify", "--context", "prod-eks", "-o", "jsonpath={.clusters[0].cluster.server}"}, exec.Result{Stdout: []byte("https://203.0.113.5:6443")})
	runner.On("kubectl", []string{"config", "use-context", "prod-eks"}, exec.Result{})
	ctx := &cli.Context{Out: &out, Err: &errOut, Stdin: strings.NewReader("1\n1\nprod-eks\n"), Runner: runner}
	if code := clusterOfferCommand(ctx); code != 0 {
		t.Fatalf("code = %d, stderr = %q, out = %q; want 0", code, errOut.String(), out.String())
	}
	if !strings.Contains(out.String(), "1) prod-eks (remote)") || strings.Contains(out.String(), "docker-desktop (remote)") {
		t.Fatalf("out = %q: the remote context must be offered, the local one not", out.String())
	}
	selected := false
	for _, c := range runner.Calls() {
		if c.Name == "kubectl" && strings.Join(c.Args, " ") == "config use-context prod-eks" {
			selected = true
		}
	}
	if !selected {
		t.Fatalf("calls = %+v, want kubectl config use-context prod-eks", runner.Calls())
	}
}
