package clustermenu

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestMinikubeMissingShowsCommand: the official command is displayed, never run
func TestMinikubeMissingShowsCommand(t *testing.T) {
	f := newFixture("2\n", false)
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false without minikube")
	}
	for _, want := range []string{"minikube is not installed", "  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64", "Then run the same command again."} {
		if !strings.Contains(f.out.String(), want) {
			t.Fatalf("out lacks %q: %q", want, f.out.String())
		}
	}
	if len(f.runner.Calls()) != 0 {
		t.Fatalf("calls = %+v, want none", f.runner.Calls())
	}
}

// TestInstallCommandByOS: brew on macOS, winget elsewhere than Linux
func TestInstallCommandByOS(t *testing.T) {
	if got := installCommand("darwin"); got != "  brew install minikube" {
		t.Fatalf("darwin: %q", got)
	}
	if got := installCommand("windows"); got != "  winget install Kubernetes.minikube" {
		t.Fatalf("windows: %q", got)
	}
}

// TestMinikubeAnswerNo: nothing is started
func TestMinikubeAnswerNo(t *testing.T) {
	f := newFixture("2\nn\n", true)
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false when the answer is no")
	}
	if f.calledWith("minikube", "start", "-p", "devzone") {
		t.Fatal("minikube start called after no")
	}
}

// TestMinikubeAnswerYes: the profile devzone is started, then selected
func TestMinikubeAnswerYes(t *testing.T) {
	f := newFixture("2\ny\n", true)
	f.runner.On("minikube", []string{"start", "-p", "devzone"}, exec.Result{})
	f.runner.On("kubectl", []string{"config", "use-context", "devzone"}, exec.Result{})
	if !f.menu.Offer() {
		t.Fatalf("Offer = false, err = %q", f.errOut.String())
	}
	if !f.calledWith("minikube", "start", "-p", "devzone") {
		t.Fatal("minikube start -p devzone not called")
	}
	if !strings.Contains(f.out.String(), "✔ minikube cluster devzone started") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestMinikubeStartFails: status false, the message, nothing else done
func TestMinikubeStartFails(t *testing.T) {
	f := newFixture("2\nyes\n", true)
	f.runner.On("minikube", []string{"start", "-p", "devzone"}, exec.Result{Code: 1, Stderr: []byte("boom")})
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false when minikube start fails")
	}
	if !strings.Contains(f.errOut.String(), "✖ minikube start failed: nothing else done") {
		t.Fatalf("err = %q", f.errOut.String())
	}
	if f.calledWith("kubectl", "config", "use-context", "devzone") {
		t.Fatal("use-context called after a failed start")
	}
}
