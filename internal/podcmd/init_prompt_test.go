package podcmd

import (
	"strings"
	"testing"
)

// expectedPromptBlock is the shell block of the startup script, spelled out so
// the tests catch any change to its exact text.
const expectedPromptBlock = "# >>> devzone prompt >>>\n" +
	"# Interactive shells in the pod must not write core files either (#961).\n" +
	"ulimit -c 0 2>/dev/null || true\n" +
	"PS1='$(devzone kube prompt) '\"$PS1\"\n" +
	"# <<< devzone prompt <<<\n"

// TestInitPromptMigratesOldBlock covers the invite-kube.sh block: its lines are
// dropped and the Go block is added once, even over two startups.
func TestInitPromptMigratesOldBlock(t *testing.T) {
	f := newInitFixture(t)
	old := "# >>> devzone prompt >>>\n" +
		". /usr/local/share/devzone/.devcontainer/invite-kube.sh\n" +
		"PS1='$(devzone_invite_kube) '\"$PS1\"\n" +
		"# <<< devzone prompt <<<\n"
	f.write(f.bashrc, old)
	if code := f.run(); code != 0 {
		t.Fatalf("first code %d; journal:\n%s", code, f.out.String())
	}
	content := f.read(f.bashrc)
	if content != expectedPromptBlock {
		t.Fatalf(".bashrc = %q, want exactly %q", content, expectedPromptBlock)
	}
	if !f.hasLogLine("prompt block migrated to the Go command") {
		t.Errorf("migration not logged:\n%s", f.out.String())
	}
	f.out.Reset()
	if code := f.run(); code != 0 {
		t.Fatalf("second code %d; journal:\n%s", code, f.out.String())
	}
	if got := f.read(f.bashrc); got != expectedPromptBlock {
		t.Fatalf("second .bashrc = %q, want one block", got)
	}
	if !f.hasLogLine("prompt block already present") {
		t.Errorf("second startup added a block:\n%s", f.out.String())
	}
}

// TestInitPromptMigratesStaleMarkers covers an old block that no longer has the
// shell symbol lines: the markers are removed without losing user settings.
func TestInitPromptMigratesStaleMarkers(t *testing.T) {
	f := newInitFixture(t)
	old := promptStart + "\nPS1='$(devzone_kube_prompt) '\"$PS1\"\n" + promptEnd + "\nexport KEEP=1\n"
	f.write(f.bashrc, old)
	if code := f.run(); code != 0 {
		t.Fatalf("code %d; journal:\n%s", code, f.out.String())
	}
	want := "export KEEP=1\n" + expectedPromptBlock
	if got := f.read(f.bashrc); got != want {
		t.Fatalf(".bashrc = %q, want %q", got, want)
	}
	if strings.Contains(f.read(f.bashrc), "devzone_kube_prompt") {
		t.Error("stale prompt line kept")
	}
}
