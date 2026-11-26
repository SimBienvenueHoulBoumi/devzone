package command

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"
)

// TestWorkspaceStartWithoutServiceManagerSucceeds keeps a successful cluster
// start on Windows and on a host without systemctl or launchctl: Go says once
// that the automatic start is unavailable and does not call enable.
func TestWorkspaceStartWithoutServiceManagerSucceeds(t *testing.T) {
	requireBash(t)
	previousAvailable, previousEnable := portsServiceManagerAvailable, commandPortsEnable
	t.Cleanup(func() {
		portsServiceManagerAvailable, commandPortsEnable = previousAvailable, previousEnable
	})
	portsServiceManagerAvailable = func() bool { return false }
	calls := 0
	commandPortsEnable = func(io.Writer, io.Writer) int {
		calls++
		return 0
	}
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if calls != 0 || len(lines) != 2 || !strings.Contains(lines[1], "automatic start is not available") {
		t.Fatalf("enable calls = %d, out = %q", calls, out.String())
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q, want nothing", errOut.String())
	}
}

// TestWorkspaceStartEnableFailureIsWarning keeps a successful cluster start
// successful when the automatic start cannot be installed afterwards.
func TestWorkspaceStartEnableFailureIsWarning(t *testing.T) {
	requireBash(t)
	previousAvailable, previousEnable := portsServiceManagerAvailable, commandPortsEnable
	t.Cleanup(func() {
		portsServiceManagerAvailable, commandPortsEnable = previousAvailable, previousEnable
	})
	portsServiceManagerAvailable = func() bool { return true }
	calls := 0
	commandPortsEnable = func(_ io.Writer, errOut io.Writer) int {
		calls++
		fmt.Fprintln(errOut, "✖ port watcher automatic start not enabled")
		return 1
	}
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, want 0 (err %q)", code, errOut.String())
	}
	if calls != 1 || !strings.HasPrefix(out.String(), "args:[workspace][start]\n") {
		t.Fatalf("enable calls = %d, out = %q", calls, out.String())
	}
	if !strings.Contains(errOut.String(), "⚠") || !strings.Contains(errOut.String(), "workspace started") {
		t.Fatalf("no warning after a failed enable: %q", errOut.String())
	}
}
