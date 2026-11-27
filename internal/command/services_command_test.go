package command

import (
	"bytes"
	"strings"
	"testing"
)

// TestServicesUnknownSubcommandAndHelp checks an unknown services subcommand
// is refused with nothing run, and the help lists services enable|disable.
func TestServicesUnknownSubcommandAndHelp(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := commandServices([]string{"services", "foo"}, &out, &errOut); code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "unknown subcommand: foo") {
		t.Fatalf("stderr = %q, want unknown subcommand: foo", errOut.String())
	}
	if !strings.Contains(helpText("test"), "services enable|disable <service>") {
		t.Fatal("help does not list services enable|disable <service>")
	}
}
