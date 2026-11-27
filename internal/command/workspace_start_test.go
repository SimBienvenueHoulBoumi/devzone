package command

import (
	"bytes"
	"strings"
	"testing"
)

// TestWorkspaceStartWithoutServiceManagerSucceeds keeps a successful cluster
// start on a host without systemctl or launchctl: Go installs nothing and says
// nothing, without changing the status of the start.

func TestWorkspaceStartWithoutServiceManagerSucceeds(t *testing.T) {
	hostMode(t)
	requireBash(t)
	fakeClusterReady(t)
	h := newAutoStartHarness(t)
	h.available = false
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if h.enableCalls != 0 || len(lines) != 1 || lines[0] != "args:[workspace][start]" {
		t.Fatalf("enable calls = %d, out = %q", h.enableCalls, out.String())
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q, want nothing", errOut.String())
	}
}

// TestWorkspaceStartEnableFailureIsWarning keeps a successful cluster start
// successful when the single automatic-start function fails afterwards: the
// reason is written on errOut, but the status stays 0.
func TestWorkspaceStartEnableFailureIsWarning(t *testing.T) {
	hostMode(t)
	requireBash(t)
	fakeClusterReady(t)
	h := newAutoStartHarness(t)
	h.enableStatus, h.enableError = 1, "✖ port watcher automatic start not enabled"
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, want 0 (err %q)", code, errOut.String())
	}
	if h.enableCalls != 1 || !strings.HasPrefix(out.String(), "args:[workspace][start]\n") {
		t.Fatalf("enable calls = %d, out = %q", h.enableCalls, out.String())
	}
	if !strings.Contains(errOut.String(), h.enableError) {
		t.Fatalf("no warning after a failed enable: %q", errOut.String())
	}
}
