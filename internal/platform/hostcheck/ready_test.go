package hostcheck

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// infoArgs are the arguments of the probe: docker info
var infoArgs = []string{"info"}

// readyWith runs Ready against a fake runner programmed with resp and err, and
// returns the result, the message and the recorded calls
func readyWith(t *testing.T, resp exec.Result, err error) (bool, string, []fake.Call) {
	t.Helper()
	r := fake.New()
	r.OnResponse("docker", infoArgs, fake.Response{Stdout: resp.Stdout, Stderr: resp.Stderr, Code: resp.Code, Err: err})
	var errOut bytes.Buffer
	ok := Ready(context.Background(), r, "docker", "make desinstaller", &errOut)
	return ok, errOut.String(), r.Calls()
}

// TestReadyAnswering: docker info succeeds, nothing is printed
func TestReadyAnswering(t *testing.T) {
	ok, msg, calls := readyWith(t, exec.Result{}, nil)
	if !ok {
		t.Fatal("Ready = false, want true when docker info succeeds")
	}
	if msg != "" {
		t.Fatalf("message = %q, want nothing", msg)
	}
	want := []fake.Call{{Name: "docker", Args: infoArgs}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %+v, want %+v", calls, want)
	}
}

// TestReadyMissing: the command cannot be started, the install message is printed
func TestReadyMissing(t *testing.T) {
	ok, msg, _ := readyWith(t, exec.Result{}, errors.New("exec: \"docker\": executable file not found in $PATH"))
	if ok {
		t.Fatal("Ready = true, want false when docker is missing")
	}
	want := "✖ Docker not found: devzone needs it to run its container.\n" +
		"  Install Docker Desktop (macOS, Windows, Linux): https://docs.docker.com/desktop/\n" +
		"  or, on Linux, Docker Engine: https://docs.docker.com/engine/install/\n" +
		"  then run make desinstaller again\n"
	if msg != want {
		t.Fatalf("message = %q, want %q", msg, want)
	}
}

// TestReadyPermissionDenied: a lowercase or capitalised "permission denied" gives the docker group message
func TestReadyPermissionDenied(t *testing.T) {
	for _, stderr := range []string{
		"permission denied while trying to connect to the Docker daemon socket",
		"Got Permission denied on the socket",
	} {
		ok, msg, _ := readyWith(t, exec.Result{Stderr: []byte(stderr), Code: 1}, nil)
		if ok {
			t.Fatalf("Ready = true for stderr %q, want false", stderr)
		}
		want := "✖ Docker denied access: your account is not in the docker group.\n" +
			"  sudo usermod -aG docker $USER, then open a new session (or newgrp docker),\n" +
			"  then run make desinstaller again\n"
		if msg != want {
			t.Fatalf("message = %q, want %q", msg, want)
		}
	}
}

// TestReadyStopped: any other failure of docker info means Docker does not respond
func TestReadyStopped(t *testing.T) {
	stderr := "failed to connect to the docker API at unix:///var/run/docker.sock"
	ok, msg, _ := readyWith(t, exec.Result{Stderr: []byte(stderr), Code: 1}, nil)
	if ok {
		t.Fatal("Ready = true, want false when docker does not respond")
	}
	want := "✖ Docker is installed but does not respond (stopped?).\n" +
		"  Start Docker Desktop (on Linux without Docker Desktop: sudo systemctl start docker),\n" +
		"  then run make desinstaller again\n"
	if msg != want {
		t.Fatalf("message = %q, want %q", msg, want)
	}
	if strings.Contains(msg, stderr) {
		t.Fatal("the raw Docker error must not be shown")
	}
}

// TestReadyUsesCommandName: the name given by the caller is the one repeated in the message
func TestReadyUsesCommandName(t *testing.T) {
	r := fake.New()
	r.OnResponse("docker", infoArgs, fake.Response{Code: 1, Stderr: []byte("stopped")})
	var errOut bytes.Buffer
	Ready(context.Background(), r, "docker", "devzone uninstall", &errOut)
	if !strings.HasSuffix(errOut.String(), "then run devzone uninstall again\n") {
		t.Fatalf("message = %q, want the given command name", errOut.String())
	}
}
