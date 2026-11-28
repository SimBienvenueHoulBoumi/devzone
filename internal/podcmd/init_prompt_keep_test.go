package podcmd

import "testing"

// TestInitPromptKeepsEditedBlock checks that a block under the current markers
// is left untouched, whatever it holds: rewriting it would leave its PS1 line
// in place and show the prompt twice.
func TestInitPromptKeepsEditedBlock(t *testing.T) {
	f := newInitFixture(t)
	edited := promptStart + "\nPS1='$(devzone kube prompt) '\"$PS1\"\n" + promptEnd + "\n"
	f.write(f.bashrc, edited)
	if code := f.run(); code != 0 {
		t.Fatalf("code %d; journal:\n%s", code, f.out.String())
	}
	if got := f.read(f.bashrc); got != edited {
		t.Fatalf(".bashrc = %q, want it untouched %q", got, edited)
	}
	if !f.hasLogLine("prompt block already present") {
		t.Errorf("not reported as already present:\n%s", f.out.String())
	}
}
