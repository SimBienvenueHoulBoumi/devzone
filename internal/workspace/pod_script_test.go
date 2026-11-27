package workspace

import (
	"bytes"
	_ "embed"
	"path/filepath"
	"strings"
	"testing"
)

// embeddedCRLFScript holds CRLF bytes on purpose: go:embed keeps the bytes of
// the checkout, as it does in a binary built on a Windows workstation.
//
//go:embed embedded_crlf.dat
var embeddedCRLFScript string

// TestLFScriptNormalizesLineEndings checks that CRLF and old Mac CR endings
// become LF before a script reaches the pod, while an LF script is unchanged.
func TestLFScriptNormalizesLineEndings(t *testing.T) {
	got := lfScript("set -eu\r\nfirst\rsecond\nlast\n")
	if want := "set -eu\nfirst\nsecond\nlast\n"; got != want {
		t.Fatalf("lfScript = %q, want %q", got, want)
	}
	if got := lfScript(got); got != "set -eu\nfirst\nsecond\nlast\n" {
		t.Fatalf("LF script changed: %q", got)
	}
}

// TestLFScriptFromEmbeddedFile checks a script that comes from a file embedded
// in the program: go:embed bakes in the CRLF bytes of a Windows checkout, so
// the pod must still receive LF when the binary was built on Windows.
func TestLFScriptFromEmbeddedFile(t *testing.T) {
	if !strings.Contains(embeddedCRLFScript, "\r\n") {
		t.Fatal("the fixture must hold CRLF bytes, as a Windows checkout would")
	}
	if got, want := lfScript(embeddedCRLFScript), "set -eu\necho embedded script\n"; got != want {
		t.Fatalf("embedded script = %q, want %q", got, want)
	}
}

// TestPodScriptsSentToKubectlAreLF checks the boundary of the three scripts
// piped to bash in the pod: the fake runner records exactly what kubectl gets.
func TestPodScriptsSentToKubectlAreLF(t *testing.T) {
	clone := cloneFake(0, "")
	Clone(clone, cloneIdentity, "https://example.test/mine.git", "", &bytes.Buffer{}, &bytes.Buffer{})
	guard := copyFake(0, "")
	copyGuard(guard, noOrigin, filepath.Join(t.TempDir(), "folder"), &bytes.Buffer{})
	legacy := &fakeRunner{replies: []reply{{match: "exec -i"}}}
	reportLegacyCopies(legacy, &bytes.Buffer{})
	for name, f := range map[string]*fakeRunner{"clone": clone, "copy guard": guard, "legacy": legacy} {
		for i, input := range f.stdins {
			if strings.Contains(input, "\r") {
				t.Errorf("%s script %d has CR: %q", name, i, input)
			}
		}
	}
}
