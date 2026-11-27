package agent

import (
	"reflect"
	"testing"
)

// TestReaperArgsWrapsSession checks that a session is started as the child of the
// subreaper word of the devzone binary when a reaper path is set, and directly
// otherwise, so that the platforms without a subreaper start sessions as before.
func TestReaperArgsWrapsSession(t *testing.T) {
	gotName, gotArgs := reaperArgs("/usr/local/bin/devzone-pod", "bash", []string{"-c", "exit 0"})
	if gotName != "/usr/local/bin/devzone-pod" {
		t.Errorf("program = %q, want the devzone binary", gotName)
	}
	wantArgs := []string{"subreaper", "--", "bash", "-c", "exit 0"}
	if !reflect.DeepEqual(gotArgs, wantArgs) {
		t.Errorf("args = %q, want %q", gotArgs, wantArgs)
	}

	name, args := reaperArgs("", "opencode", []string{"run"})
	if name != "opencode" || !reflect.DeepEqual(args, []string{"run"}) {
		t.Errorf("without reaper: %q %q, want the session unchanged", name, args)
	}
}
