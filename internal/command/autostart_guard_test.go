package command

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// TestAutoStartGuardsLeaveDisposableHomeEmpty proves that under bats and in CI
// the automatic start opens nothing: no file appears in a disposable HOME and
// no call reaches the service manager, even from a devzone folder.
func TestAutoStartGuardsLeaveDisposableHomeEmpty(t *testing.T) {
	for _, tc := range []struct {
		name string
		bats bool
		ci   bool
	}{
		{"bats", true, false},
		{"CI", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			root := t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("HOME", home)
			t.Setenv("XDG_CACHE_HOME", home)
			t.Setenv("XDG_CONFIG_HOME", home)
			t.Setenv("DEVZONE_PORTS_AGENT_DIR", "")
			t.Setenv("DEVZONE_ROOT", root)
			t.Setenv("BATS_TEST_TMPDIR", "")
			t.Setenv("CI", "")
			t.Setenv("GITHUB_ACTIONS", "")
			t.Setenv("GITLAB_CI", "")
			for _, key := range containerEnvironmentVars {
				t.Setenv(key, "")
			}
			if tc.bats {
				t.Setenv("BATS_TEST_TMPDIR", t.TempDir())
			}
			if tc.ci {
				t.Setenv("CI", "true")
			}
			oldTest, oldEnable := portsIsTest, commandPortsEnable
			t.Cleanup(func() {
				portsIsTest, commandPortsEnable = oldTest, oldEnable
			})
			if tc.ci {
				// Only the CI gate must stop the installation here.
				portsIsTest = func() bool { return false }
			}
			calls := 0
			commandPortsEnable = func(io.Writer, io.Writer) int {
				calls++
				return 0
			}
			var out, errOut bytes.Buffer
			EnsurePortsAutoStart(&out, &errOut)
			if calls != 0 || out.Len() != 0 || errOut.Len() != 0 {
				t.Fatalf("calls = %d, out = %q, err = %q", calls, out.String(), errOut.String())
			}
			entries, err := os.ReadDir(home)
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != 0 {
				t.Fatalf("disposable HOME is not empty: %v", entries)
			}
		})
	}
}
