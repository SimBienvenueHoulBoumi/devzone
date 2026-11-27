package guard

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// parityCase is one frozen command of the parity corpus, with the status and
// the refusal kind measured against the installed guard during development.
type parityCase struct {
	cmd  string
	code int
	kube bool
}

// callInput builds the tool call of one format for a shell command.
func callInput(t *testing.T, format, cmd string) string {
	t.Helper()
	var doc any
	if format == "claude" {
		doc = map[string]any{"tool_name": "Bash", "tool_input": map[string]any{"command": cmd}}
	} else {
		doc = map[string]any{"tool": "bash", "args": map[string]any{"command": cmd}, "cwd": "/tmp"}
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// frozenCases joins the four parts of the corpus.
func frozenCases() []parityCase {
	var all []parityCase
	for _, part := range [][]parityCase{parityCasesA, parityCasesB, parityCasesC, parityCasesD} {
		all = append(all, part...)
	}
	return all
}

// TestFrozenParityCorpus checks every frozen command in both call formats:
// status and refusal text must stay identical to the installed guard.
func TestFrozenParityCorpus(t *testing.T) {
	messages := DefaultMessages()
	if len(frozenCases()) != 567 {
		t.Fatalf("corpus has %d cases, want 567", len(frozenCases()))
	}
	for _, tc := range frozenCases() {
		for _, format := range []string{"opencode", "claude"} {
			var errOut bytes.Buffer
			code := Run(strings.NewReader(callInput(t, format, tc.cmd)), format, false, &errOut, messages)
			want := ""
			if tc.code == 2 {
				want = messages.Refusal
				if tc.kube {
					want = messages.KubeRefusal
				}
			}
			if code != tc.code || strings.TrimSpace(errOut.String()) != want {
				t.Errorf("%s %q: code %d, stderr %q; want %d and %q", format, tc.cmd, code, errOut.String(), tc.code, want)
			}
		}
	}
}

// TestHostOverrideKeepsAdministratorRefusal checks that the override only
// lifts the other refusals, never the administrator context one.
func TestHostOverrideKeepsAdministratorRefusal(t *testing.T) {
	messages := DefaultMessages()
	var errOut bytes.Buffer
	code := Run(strings.NewReader(callInput(t, "opencode", "cat ~/.kube/hote.config")), "opencode", true, &errOut, messages)
	if code != 2 || strings.TrimSpace(errOut.String()) != messages.KubeRefusal {
		t.Fatalf("kube code %d, stderr %q", code, errOut.String())
	}
	errOut.Reset()
	code = Run(strings.NewReader(callInput(t, "opencode", "kubectl get pods")), "opencode", true, &errOut, messages)
	if code != 0 || errOut.Len() != 0 {
		t.Fatalf("allowed code %d, stderr %q", code, errOut.String())
	}
}

// TestNonShellCallsAreIgnored checks that a refusal word in another tool's
// content never blocks the call.
func TestNonShellCallsAreIgnored(t *testing.T) {
	for _, input := range []string{
		`{"tool":"write","args":{"content":"kubectl get pods","filePath":"x"}}`,
		`{"tool_name":"Write","tool_input":{"content":"kubectl get pods","file_path":"x"}}`,
		`not json {{{`,
		``,
	} {
		var errOut bytes.Buffer
		if code := Run(strings.NewReader(input), "opencode", false, &errOut, DefaultMessages()); code != 0 {
			t.Errorf("input %q: code %d, want 0", input, code)
		}
	}
}
