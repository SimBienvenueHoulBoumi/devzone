package podcmd

import (
	"strings"
	"testing"
)

// TestHelpCommandsPrintList checks that all three help names print the same
// command list as the removed shell library, without reaching the shell.
func TestHelpCommandsPrintList(t *testing.T) {
	noShell(t)
	for _, name := range []string{"help", "-h", "--help"} {
		out, errOut, code := runVersion(t, name)
		if code != 0 || errOut != "" {
			t.Fatalf("%s: code = %d, errOut = %q", name, code, errOut)
		}
		if out != podHelpText {
			t.Fatalf("%s: help text differs:\nwant:\n%s\ngot:\n%s", name, podHelpText, out)
		}
	}
}

// TestHelpKeepsDocumentedCommands protects the command names cited by the
// README and by the former bats tests of devzone.bats.
func TestHelpKeepsDocumentedCommands(t *testing.T) {
	for _, want := range []string{
		"devzone --version",
		"devzone platform github",
		"devzone platform gitlab",
		"[--url URL]",
		"devzone test-bash32",
		"devzone agent <folder> <instructions>",
		"devzone catalog ",
		"devzone port [--close <n>]",
		"devzone packages [add|remove|apply]",
	} {
		if !strings.Contains(podHelpText, want) {
			t.Errorf("help text misses %q", want)
		}
	}
}

// TestHandlesHelp checks that the launcher sends help names to the Go binary
// instead of sourcing a shell library again.
func TestHandlesHelp(t *testing.T) {
	for _, name := range []string{"help", "-h", "--help"} {
		out, errOut, code := runVersion(t, "handles", name)
		if code != 0 || out != "" || errOut != "" {
			t.Fatalf("handles %s: code = %d, out = %q, errOut = %q", name, code, out, errOut)
		}
	}
}
