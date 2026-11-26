package podcmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestAICommandIsPorted checks that the launcher routes the AI command to Go.
func TestAICommandIsPorted(t *testing.T) {
	if got := Run([]string{"handles", "ai"}, &bytes.Buffer{}, &bytes.Buffer{}); got != 0 {
		t.Fatalf("handles ai: got %d, want 0", got)
	}
}

// TestAIGuardRefusesToolCall checks that the guard subcommand reads a call on
// standard input and writes its refusal on the error writer.
func TestAIGuardRefusesToolCall(t *testing.T) {
	command, ok := Registry.Lookup("ai")
	if !ok {
		t.Fatal("ai is not registered")
	}
	input := `{"tool":"bash","args":{"command":"` + "\x64\x6f\x63\x6b\x65\x72" + ` ps"},"cwd":"/tmp"}`
	var errOut bytes.Buffer
	code := command.Run(&cli.Context{
		Args:   []string{"guard"},
		Err:    &errOut,
		Stdin:  strings.NewReader(input),
		Runner: nil,
	})
	if code != 2 || !strings.Contains(errOut.String(), "Kubernetes") {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
}

// TestAIApplyNeedsMode checks that the assistant application needs on or off.
func TestAIApplyNeedsMode(t *testing.T) {
	command, _ := Registry.Lookup("ai")
	var errOut bytes.Buffer
	if code := command.Run(&cli.Context{Args: []string{"apply"}, Err: &errOut}); code != 2 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
}
