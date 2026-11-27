package podcmd

import (
	"strings"
	"testing"
)

// TestConfirmRemovalAnswers checks the prompt of a removal that deletes data:
// a yes deletes the data, a refusal of postgres cancels, a refusal of mysql
// still disables.
func TestConfirmRemovalAnswers(t *testing.T) {
	cases := []struct {
		name, app, answer   string
		proceed, deleteData bool
		abortedMsg          bool
	}{
		{"postgres yes", "postgres", "y\n", true, true, false},
		{"postgres refused", "postgres", "n\n", false, false, true},
		{"mysql refused keeps data", "mysql", "\n", true, false, false},
		{"gitlab yes", "gitlab", "yes\n", true, true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newModuleFixture(t, c.app+"=on")
			f.m.interactive = true
			f.m.ctx.Stdin = strings.NewReader(c.answer)
			if got := f.m.confirmRemoval(c.app, nil); got != c.proceed {
				t.Fatalf("proceed = %v, want %v", got, c.proceed)
			}
			if f.m.deleteData != c.deleteData {
				t.Fatalf("deleteData = %v, want %v", f.m.deleteData, c.deleteData)
			}
			if strings.Contains(f.out.String(), "Aborted: nothing was deleted.") != c.abortedMsg {
				t.Fatalf("stdout = %q", f.out.String())
			}
			if !strings.Contains(f.errOut.String(), "[y/N]") {
				t.Fatalf("no prompt on stderr: %q", f.errOut.String())
			}
		})
	}
}

// TestConfirmRemovalSkipped checks that no question is asked without a terminal
// or when --yes is given: the data is then deleted only with --yes.
func TestConfirmRemovalSkipped(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.m.interactive = false
	if !f.m.confirmRemoval("postgres", nil) || f.m.deleteData {
		t.Fatalf("without a terminal: deleteData %v", f.m.deleteData)
	}
	if f.errOut.Len() != 0 {
		t.Fatalf("question asked: %q", f.errOut.String())
	}
	if !f.m.confirmRemoval("postgres", []string{"--yes"}) || !f.m.deleteData {
		t.Fatalf("--yes: deleteData %v", f.m.deleteData)
	}
}

// TestDisablePostgresDeletesWithYes checks the full removal of postgres with --yes:
// the hook of Argo CD runs first, then the uninstaller.
func TestDisablePostgresDeletesWithYes(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.pod.outs["postgres status"] = "absent\n"
	if code := f.m.changeModule("off", "postgres", []string{"--yes"}); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(f.state(t), "postgres=off") {
		t.Fatalf("state = %q", f.state(t))
	}
	if !f.pod.has("argocd services-hook postgres off --yes") {
		t.Fatalf("hook not called: %v", f.pod.calls)
	}
}
