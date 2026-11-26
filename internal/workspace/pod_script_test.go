package workspace

import (
	"bytes"
	_ "embed"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// embeddedCRLFScript holds CRLF bytes on purpose: go:embed keeps the bytes of
// the checkout, as it does in a binary built on a Windows workstation.
//
//go:embed embedded_crlf.dat
var embeddedCRLFScript string

// bashScriptsFiles are the bash files that hold the scripts run in the pod, as
// seen from this package
var bashScriptsFiles = []string{
	"../../manage/scripts/workspace/workspace-copies.sh",
	"../../manage/scripts/workspace/workspace-clone.sh",
}

// bashPodScript returns the script that the bash function function sends to the
// pod: the lines between the first "cat <<'POD'" after its definition and the
// closing "POD", in whichever of bashScriptsFiles defines the function. Both
// copies (bash and Go) must hold the same text.
func bashPodScript(t *testing.T, function string) string {
	t.Helper()
	for _, file := range bashScriptsFiles {
		if script, ok := heredocOf(t, file, function); ok {
			return script
		}
	}
	t.Fatalf("function %s not found in %s", function, strings.Join(bashScriptsFiles, ", "))
	return ""
}

// heredocOf returns the heredoc of the function defined in file, and false when
// the file does not define it
func heredocOf(t *testing.T, file, function string) (string, bool) {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(file))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(data), "\n")
	start := -1
	for i, line := range lines {
		if line == function+"() {" {
			start = i
			break
		}
	}
	if start < 0 {
		return "", false
	}
	var script []string
	inHeredoc := false
	for _, line := range lines[start:] {
		if !inHeredoc {
			inHeredoc = strings.TrimSpace(line) == "cat <<'POD'"
			continue
		}
		if line == "POD" {
			return strings.Join(script, "\n") + "\n", true
		}
		script = append(script, line)
	}
	t.Fatalf("heredoc of %s not closed in %s", function, file)
	return "", false
}

// TestLegacyScriptMatchesBash checks that podScript (legacy.go) is the script of
// workspace_legacy_pod_script in manage/scripts/workspace/workspace-copies.sh
func TestLegacyScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_legacy_pod_script"); podScript != want {
		t.Fatalf("podScript differs from the bash script:\n%s\nwant:\n%s", podScript, want)
	}
}

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
