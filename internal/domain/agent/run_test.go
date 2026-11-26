package agent

import (
	"context"
	"os"
	"strings"
	"testing"
)

func runAgent(t *testing.T, s *sandbox, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut strings.Builder
	o := s.opts()
	o.Out = &out
	o.Err = &errOut
	code := Run(context.Background(), o, args)
	return code, out.String(), errOut.String()
}

func TestRunHelpAndUsage(t *testing.T) {
	s := newSandbox(t)
	if code, out, _ := runAgent(t, s); code != 2 || !strings.Contains(out, "usage: devzone agent") {
		t.Fatal("no-args", code, out)
	}
	if code, _, _ := runAgent(t, s, "--help"); code != 0 {
		t.Fatal("help")
	}
	if code, _, _ := runAgent(t, s, "help"); code != 0 {
		t.Fatal("help cmd")
	}
	// release without arg refused
	if code, _, _ := runAgent(t, s, "release"); code != 2 {
		t.Fatal("release no arg", code)
	}
	// fewer than 2 args
	if code, _, _ := runAgent(t, s, "--local", s.proj); code != 2 {
		t.Fatal("needs 2 args", code)
	}
	// --model needs value
	if code, _, _ := runAgent(t, s, "--model"); code != 2 {
		t.Fatal("--model no value", code)
	}
}

func TestRunRelease(t *testing.T) {
	s := newSandbox(t)
	os.MkdirAll(s.state, 0o755)
	os.WriteFile(s.state+"/ecart-big-pickle", []byte("x pays 604800\n"), 0o644)
	if code, _, _ := runAgent(t, s, "release", "big-pickle"); code != 0 {
		t.Fatal("release")
	}
	if fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("not released")
	}
	os.WriteFile(s.state+"/ecart-a", []byte("x"), 0o644)
	if code, _, _ := runAgent(t, s, "release", "--all"); code != 0 {
		t.Fatal("release --all")
	}
	if fileExists(s.state + "/ecart-a") {
		t.Fatal("--all not released")
	}
}

func TestRunModelNotSupportedWithPod(t *testing.T) {
	s := newSandbox(t)
	if code, _, errOut := runAgent(t, s, "--model", "big-pickle", "--pod", s.proj, s.brief); code != 2 || !strings.Contains(errOut, "not supported with --pod") {
		t.Fatal("model+pod", code, errOut)
	}
	if opLog() != "" {
		t.Fatal("launched")
	}
}

func TestRunStateText(t *testing.T) {
	s := newSandbox(t)
	if code, out, _ := runAgent(t, s, "state"); code != 0 || !strings.Contains(out, "devzone agent: state") {
		t.Fatal("state", code, out)
	}
}

func TestRunStateJSON(t *testing.T) {
	s := newSandbox(t)
	if code, out, _ := runAgent(t, s, "state", "--json"); code != 0 || !strings.Contains(out, `"schema":2`) {
		t.Fatal("json", code, out)
	}
}

func TestRunStatus(t *testing.T) {
	s := newSandbox(t)
	if code, _, _ := runAgent(t, s, "status"); code != 0 {
		t.Fatal("status", code)
	}
}

func TestRunLocal(t *testing.T) {
	s := newSandbox(t)
	if code, _, _ := runAgent(t, s, "--local", s.proj, s.brief); code != 0 {
		t.Fatal("local", code)
	}
	if len(modelsLaunched()) != 1 {
		t.Fatal("local launch", modelsLaunched())
	}
}
