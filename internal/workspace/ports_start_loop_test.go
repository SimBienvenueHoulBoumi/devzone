//go:build !windows

package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// kubectlWitness is a fake kubectl whose answer to "ss -ltnH" depends on the
// existence of the witness file in the state folder: no listener without it,
// the 39001 listener with it. Every other call answers nothing, and
// port-forward becomes a sleep so that the relay pid is the sleep's one.
const kubectlWitness = `#!/usr/bin/env bash
case "$*" in
*"config get-contexts"*) printf '%s' "" ;;
*"get svc -A"*) printf '%s' "" ;;
*"get endpointslices"*) printf '%s' "" ;;
*"ss -ltnH"*)
  if [ -e "$DEVZONE_PORTS_WORKSPACE_DIR/witness" ]; then
    printf 'LISTEN 0 128 0.0.0.0:39001 0.0.0.0:*\n'
  fi
  ;;
*"port-forward"*) exec sleep 600 ;;
*) exit 1 ;;
esac
`

const port39001 = "39001"

// warningEndpoints is the one-line warning printed once on the error output
// when the endpoint slices cannot be read.
const warningEndpoints = "⚠ endpointslices unreadable, ready pods not checked"

// TestPortsStartJournalKeepsErrors: what the watcher writes on its error
// output (the endpointslices warning) is appended to journal.log, because
// launchWatcher redirects both streams of the loop to the journal.
func TestPortsStartJournalKeepsErrors(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	t.Setenv("FAKE_READY_FAIL", "1")
	t.Setenv("FAKE_SVC", svcLine("default", "web", 8080))
	le.useBinary()
	journal := filepath.Join(dir, "journal.log")
	if got := le.run("workspace", "ports", "start"); !strings.HasPrefix(got, "Workspace ports: watcher started, log ") {
		t.Fatalf("start: %q", got)
	}
	if !waitUntil(5*time.Second, func() bool {
		return strings.Contains(readAll(journal), warningEndpoints)
	}) {
		t.Fatalf("the endpointslices warning is missing from journal.log: %q", readAll(journal))
	}
	if got := le.run("workspace", "ports", "stop"); got != "" {
		t.Fatalf("stop printed %q", got)
	}
}

// TestPortsStartRunsAgainAfterTheStep: a second round runs after the step,
// because PortsLoop pauses with time.After(step) between two rounds.
func TestPortsStartRunsAgainAfterTheStep(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	// Replace the fake kubectl: the listener on 39001 exists only when the
	// witness file is present in the state folder.
	if err := os.WriteFile(filepath.Join(le.h.dir, "bin", "kubectl"), []byte(kubectlWitness), 0o755); err != nil {
		t.Fatal(err)
	}
	relayFile := filepath.Join(dir, "relays", port39001)
	witness := filepath.Join(dir, "witness")
	le.useBinary()
	if got := le.run("workspace", "ports", "start"); !strings.HasPrefix(got, "Workspace ports: watcher started, log ") {
		t.Fatalf("start: %q", got)
	}
	time.Sleep(2 * time.Second)
	if exists(relayFile) {
		t.Fatalf("a relay exists on 39001 without the witness file")
	}
	if err := os.WriteFile(witness, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if !waitUntil(5*time.Second, func() bool { return exists(relayFile) }) {
		t.Fatalf("relay 39001 did not appear after the witness file was created")
	}
	if err := os.Remove(witness); err != nil {
		t.Fatal(err)
	}
	if !waitUntil(5*time.Second, func() bool { return !exists(relayFile) }) {
		t.Fatalf("relay 39001 did not disappear after the witness file was removed")
	}
	if got := le.run("workspace", "ports", "stop"); got != "" {
		t.Fatalf("stop printed %q", got)
	}
}
