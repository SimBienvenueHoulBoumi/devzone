package command

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"
)

// autoStartHarness injects every gate and effect of the automatic start: no
// real service manager, watcher, personal folder or devzone folder is touched.
type autoStartHarness struct {
	enableCalls  int
	enableStatus int
	enableError  string
	installed    bool
	upToDate     bool
	workstation  bool
	ci           bool
	underTest    bool
	available    bool
	refused      bool
}

// newAutoStartHarness installs fakes for the gates and the enable call of the
// automatic start, and restores them after the test.
func newAutoStartHarness(t *testing.T) *autoStartHarness {
	t.Helper()
	h := &autoStartHarness{workstation: true, available: true}
	oldEnsure, oldEnable, oldExists := commandEnsureAutoStart, commandPortsEnable, commandPortsAutoStartExists
	oldUpToDate, oldWorkstation, oldCI := commandPortsWatcherUpToDate, portsIsWorkstation, portsIsCI
	oldTest, oldAvailable, oldRefused := portsIsTest, portsServiceManagerAvailable, commandPortsRefusalIsSet
	oldMemorize, oldForget, oldFailed := commandMemorizePortsRefusal, commandForgetPortsRefusal, commandPortsAutoStartFailed
	t.Cleanup(func() {
		commandEnsureAutoStart, commandPortsEnable, commandPortsAutoStartExists = oldEnsure, oldEnable, oldExists
		commandPortsWatcherUpToDate, portsIsWorkstation, portsIsCI = oldUpToDate, oldWorkstation, oldCI
		portsIsTest, portsServiceManagerAvailable, commandPortsRefusalIsSet = oldTest, oldAvailable, oldRefused
		commandMemorizePortsRefusal, commandForgetPortsRefusal, commandPortsAutoStartFailed = oldMemorize, oldForget, oldFailed
	})
	commandEnsureAutoStart = EnsurePortsAutoStart
	commandPortsEnable = func(_ io.Writer, errOut io.Writer) int {
		h.enableCalls++
		if h.enableError != "" {
			fmt.Fprintln(errOut, h.enableError)
		}
		h.installed = true
		h.upToDate = true
		return h.enableStatus
	}
	commandPortsAutoStartExists = func() bool { return h.installed }
	commandPortsWatcherUpToDate = func() bool { return h.upToDate }
	portsIsWorkstation = func() bool { return h.workstation }
	portsIsCI = func() bool { return h.ci }
	portsIsTest = func() bool { return h.underTest }
	portsServiceManagerAvailable = func() bool { return h.available }
	commandPortsRefusalIsSet = func() bool { return h.refused }
	commandPortsAutoStartFailed = func() bool { return false }
	commandMemorizePortsRefusal = func() {}
	commandForgetPortsRefusal = func() {}
	return h
}

// TestEnsureFirstInstallSaysOnce checks that the first installation prints one
// line with the command that removes the automatic start.

func TestEnsureFirstInstallSaysOnce(t *testing.T) {
	h := newAutoStartHarness(t)
	var out, errOut bytes.Buffer
	EnsurePortsAutoStart(&out, &errOut)
	if h.enableCalls != 1 || errOut.Len() != 0 {
		t.Fatalf("enable calls = %d, err = %q", h.enableCalls, errOut.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 1 || !strings.Contains(lines[0], "devzone workspace ports disable") {
		t.Fatalf("stdout = %q, want one line with the removal command", out.String())
	}
}

// TestEnsureSilentWhenCurrent checks that an installed and current watcher
// makes no call at all to the service manager and prints nothing.
func TestEnsureSilentWhenCurrent(t *testing.T) {
	h := newAutoStartHarness(t)
	h.installed, h.upToDate = true, true
	var out, errOut bytes.Buffer
	EnsurePortsAutoStart(&out, &errOut)
	if h.enableCalls != 0 || out.Len() != 0 || errOut.Len() != 0 {
		t.Fatalf("calls = %d, out = %q, err = %q", h.enableCalls, out.String(), errOut.String())
	}
}

// TestEnsureRepairsSilently checks that an old copy is replaced without a new
// announcement, while the service manager is called again.
func TestEnsureRepairsSilently(t *testing.T) {
	h := newAutoStartHarness(t)
	h.installed, h.upToDate = true, false
	var out, errOut bytes.Buffer
	EnsurePortsAutoStart(&out, &errOut)
	if h.enableCalls != 1 || out.Len() != 0 || errOut.Len() != 0 {
		t.Fatalf("calls = %d, out = %q, err = %q", h.enableCalls, out.String(), errOut.String())
	}
}

// TestEnsureNeverFailsCommand checks that a failed installation is a warning
// on errOut and never a non-zero status of the user's command.
func TestEnsureNeverFailsCommand(t *testing.T) {
	h := newAutoStartHarness(t)
	h.enableStatus, h.enableError = 1, "✖ port watcher automatic start not enabled"
	var out, errOut bytes.Buffer
	EnsurePortsAutoStart(&out, &errOut)
	if h.enableCalls != 1 || out.Len() != 0 || !strings.Contains(errOut.String(), h.enableError) {
		t.Fatalf("calls = %d, out = %q, err = %q", h.enableCalls, out.String(), errOut.String())
	}
}

// TestEnsureDoesNothingOnGuardedHosts checks every case where no installation
// may happen, including a memorised refusal, without reaching any real effect.
func TestEnsureDoesNothingOnGuardedHosts(t *testing.T) {
	hostMode(t)
	cases := []struct {
		name  string
		setup func(*autoStartHarness)
	}{
		{"pod or container", func(h *autoStartHarness) { h.workstation = false }},
		{"CI", func(h *autoStartHarness) { h.ci = true }},
		{"tests", func(h *autoStartHarness) { h.underTest = true }},
		{"no service manager", func(h *autoStartHarness) { h.available = false }},
		{"refused", func(h *autoStartHarness) { h.refused = true }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newAutoStartHarness(t)
			tc.setup(h)
			var out, errOut bytes.Buffer
			EnsurePortsAutoStart(&out, &errOut)
			if h.enableCalls != 0 || out.Len() != 0 || errOut.Len() != 0 {
				t.Fatalf("calls = %d, out = %q, err = %q", h.enableCalls, out.String(), errOut.String())
			}
		})
	}
}
