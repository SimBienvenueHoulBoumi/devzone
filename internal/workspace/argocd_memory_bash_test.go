package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
)

// argocdMemoryBashRe replaces the shell ending of the refusal message with the
// Go ending, so that the error output of both can be compared.
var argocdMemoryBashRe = regexp.MustCompile(`enlarge the cluster \([^)]*\), then:`)

// argocdMemoryBash runs argocd_memory_ok of the bash original, sourced, in a
// folder with a fake kubectl, and returns the standard output, the error output
// and the status.
func argocdMemoryBash(t *testing.T, body string, env []string) (string, string, int) {
	t.Helper()
	script, root := argocdBashScript(t)
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	kubectl := `#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$*" in
*"config get-contexts"*) printf '%s' "${FAKE_CONTEXTS:-}"; exit 0 ;;
*"get nodes"*) printf '%s' "${FAKE_NODES:-}"; exit "${FAKE_STATUS:-0}" ;;
esac
exit "${FAKE_STATUS:-0}"
`
	if err := os.WriteFile(filepath.Join(dir, "bin", "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", `. "$1"; `+body, "_", script)
	var out, errOut bytes.Buffer
	cmd.Dir = dir
	cmd.Stdout, cmd.Stderr = &out, &errOut
	cmd.Env = append(os.Environ(), "LC_ALL=C", "RACINE="+root, "PATH="+filepath.Join(dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	cmd.Env = append(cmd.Env, env...)
	status := 0
	if err := cmd.Run(); err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("cannot run bash: %v", err)
		}
		status = exitErr.ExitCode()
	}
	return out.String(), errOut.String(), status
}

// argocdMemoryBashErr normalizes the error output of the bash memory check.
func argocdMemoryBashErr(errOut string) string {
	return argocdMemoryBashRe.ReplaceAllString(errOut, `enlarge the memory of the cluster, then:`)
}

const (
	argocdNodesCallDevzone = `--context devzone get nodes -o jsonpath={range .items[*]}{.status.allocatable.memory}{"\n"}{end}`
	argocdNodesCallCurrent = `get nodes -o jsonpath={range .items[*]}{.status.allocatable.memory}{"\n"}{end}`
	argocdNoFlag           = `kubectl_flag() { :; }; argocd_memory_ok`
	argocdDevzoneFlag      = `kubectl_flag() { echo --context devzone; :; }; argocd_memory_ok`
)

// TestArgocdMemoryOKMatchesBash compares argocdMemoryOK with argocd_memory_ok
// of the bash original: the status, the error output and the kubectl arguments,
// on an output of nodes reduced to newlines as well as on a real one.
func TestArgocdMemoryOKMatchesBash(t *testing.T) {
	cases := []struct {
		name       string
		contexts   string
		nodes      string
		status     int
		wantStatus int
		wantErr    string
		wantCall   string
		body       string
	}{
		{"sufficient memory", devzoneContexts, "4Gi\n", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"exact 1 Gi passes with two nodes", devzoneContexts, "512Mi\n512Mi", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"just below 1 Gi", devzoneContexts, "1048575Ki\n", 0, 2, argocdMemoryRefusal, argocdNodesCallDevzone, argocdDevzoneFlag},
		{"mixed units of several nodes", devzoneContexts, "1Gi\n512Mi\n256Ki", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"empty lines are ignored", devzoneContexts, "1Gi\n\n512Mi", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"empty output", devzoneContexts, "", 0, 2, argocdMemoryUnreachable, argocdNodesCallDevzone, argocdDevzoneFlag},
		{"output of a single newline", devzoneContexts, "\n", 0, 2, argocdMemoryUnreachable, argocdNodesCallDevzone, argocdDevzoneFlag},
		{"output of newlines only", devzoneContexts, "\n\n\n", 0, 2, argocdMemoryUnreachable, argocdNodesCallDevzone, argocdDevzoneFlag},
		{"trailing newlines after a value", devzoneContexts, "4Gi\n\n", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"failing kubectl is treated as empty", devzoneContexts, "2Gi\n", 1, 2, argocdMemoryUnreachable, argocdNodesCallDevzone, argocdDevzoneFlag},
		{"context flag when devzone is declared", devzoneContexts, "4Gi\n", 0, 0, "", argocdNodesCallDevzone, argocdDevzoneFlag},
		{"no context flag when context is current", currentContext, "4Gi\n", 0, 0, "", argocdNodesCallCurrent, argocdNoFlag},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			log := filepath.Join(t.TempDir(), "kubectl.log")
			t.Setenv("FAKE_LOG", log)
			t.Setenv("FAKE_CONTEXTS", tc.contexts)
			t.Setenv("FAKE_NODES", tc.nodes)
			t.Setenv("FAKE_STATUS", strconv.Itoa(tc.status))
			_, bashErr, bashStatus := argocdMemoryBash(t, tc.body,
				[]string{
					"FAKE_LOG=" + log,
					"FAKE_STATUS=" + strconv.Itoa(tc.status),
					"FAKE_CONTEXTS=" + tc.contexts,
					"FAKE_NODES=" + tc.nodes,
				})
			r := &fakeRunner{replies: []reply{
				{match: contextsCall, stdout: tc.contexts},
				{match: "get nodes -o jsonpath", stdout: tc.nodes, status: tc.status},
			}}
			status, errOut := argocdMemoryRun(r)
			if bashStatus != tc.wantStatus || status != tc.wantStatus {
				t.Fatalf("bash status %d, Go status %d; want %d", bashStatus, status, tc.wantStatus)
			}
			if got := argocdMemoryBashErr(bashErr); got != errOut {
				t.Fatalf("bash error output %q, Go error output %q; want %q", bashErr, errOut, tc.wantErr)
			}
			wantCalls(t, readArgocdCalls(t, log), tc.wantCall)
			wantCalls(t, r.calls, contextsCall, tc.wantCall)
		})
	}
}
