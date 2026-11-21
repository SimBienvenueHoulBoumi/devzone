package command

import (
	"bytes"
	"strings"
	"testing"
)

func TestHelpTextInsertsVersion(t *testing.T) {
	text := helpText("1.4.2")
	if !strings.HasPrefix(text, "devzone 1.4.2: ") {
		t.Fatalf("first line = %q, want the version after devzone", text)
	}
	if strings.Contains(text, "{version}") {
		t.Fatal("placeholder left in the help text")
	}
	if !strings.HasSuffix(text, "  devzone --version\n") {
		t.Fatalf("help text does not end with the --version line: %q", text)
	}
}

func TestHelpAliases(t *testing.T) {
	setupPackage(t, "1.4.2")
	want := helpText("1.4.2")
	for _, args := range [][]string{nil, {"help"}, {"-h"}, {"--help"}} {
		var out, errOut bytes.Buffer
		if got := Run(args, &out, &errOut); got != 0 {
			t.Fatalf("Run(%q): exit status = %d, want 0", args, got)
		}
		if out.String() != want {
			t.Fatalf("Run(%q): stdout differs from the help text", args)
		}
		if errOut.Len() != 0 {
			t.Fatalf("Run(%q): stderr = %q, want nothing", args, errOut.String())
		}
	}
}

func TestHelpWithArgumentIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out bytes.Buffer
	if got := Run([]string{"help", "x y"}, &out, &bytes.Buffer{}); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if out.String() != "args:[help][x y]\n" {
		t.Fatalf("stdout = %q, want the command line passed to bash", out.String())
	}
}
