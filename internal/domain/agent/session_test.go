package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestSessionModelStart(t *testing.T) {
	dir := t.TempDir()
	j := filepath.Join(dir, "x.log")
	os.WriteFile(j, []byte("model text: opencode/agent.json is read\n=== model opencode/beam-free start 2026-11-06T00:00:00Z\nmore text: opencode/agent.json\n"), 0o644)
	m, s := SessionModelStart(j)
	if m != "beam-free" || s != "2026-11-06T00:00:00Z" {
		t.Fatal(m, s)
	}
}

func TestSessionRequest(t *testing.T) {
	dir := t.TempDir()
	j := filepath.Join(dir, "x.log")
	os.WriteFile(j, []byte("=== --model : none\n=== --model : hy4-flash-free\n"), 0o644)
	if SessionRequest(j) != "hy4-flash-free" {
		t.Fatal("requested", SessionRequest(j))
	}
	os.WriteFile(j, []byte("=== --model : none\n"), 0o644)
	if SessionRequest(j) != "" {
		t.Fatal("none not empty")
	}
}

func TestSessionRunning(t *testing.T) {
	ps := "/usr/bin/bash /x/agent.sh /a/projet /brief\nother line\n"
	if !SessionRunning("projet", ps) {
		t.Fatal("not running")
	}
	if SessionRunning("projetx", ps) {
		t.Fatal("false match")
	}
	if SessionRunning("d", "agent.sh /a/dz-308 /brief\n") {
		t.Fatal("d matched dz-308")
	}
}

// TestSessionRunningLauncherLines checks every real command line that starts
// an agent session, and that other agents on the machine stay invisible.
func TestSessionRunningLauncherLines(t *testing.T) {
	const bin = "/usr/local/share/devzone/.devcontainer/bin/devzone-pod-linux-"
	cases := []struct {
		name, ps, project string
		want              bool
	}{
		{"launcher amd64", bin + "amd64 agent /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"launcher arm64", bin + "arm64 agent /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"local before folder", bin + "amd64 agent --local /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"model before folder", bin + "amd64 agent --model big-pickle,hy4-flash-free /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"model and local", bin + "amd64 agent --model big-pickle --local /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"pod before folder", bin + "amd64 agent --pod /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"shell launcher", "bash /workspaces/devzone/.devcontainer/devzone agent /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"old shell kept readable", "bash /workspaces/devzone/.devcontainer/agent.sh /workspaces/projets/dz-878 /consigne.md\n", "dz-878", true},
		{"other agent session", bin + "amd64 agent /workspaces/projets/dz-879 /consigne.md\n", "dz-878", false},
		{"other agent session with model", bin + "amd64 agent --model big-pickle --local /workspaces/projets/dz-879 /consigne.md\n", "dz-878", false},
		{"state is not a session", bin + "amd64 agent state\n", "state", false},
		{"release is not a session", bin + "amd64 agent release --all\n", "release", false},
		{"binary without subcommand", bin + "amd64 --version\n", "amd64", false},
		{"unrelated script", "cat /tmp/agent.sh /workspaces/projets/dz-878\n", "dz-878", false},
		{"ps command itself", "ps -eo args=\n", "ps", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := SessionRunning(c.project, c.ps); got != c.want {
				t.Fatalf("SessionRunning(%q) = %v, want %v ; ps: %q", c.project, got, c.want, c.ps)
			}
		})
	}
}

func TestLockTakeRelease(t *testing.T) {
	state := t.TempDir()
	clock := &FakeClock{NowTime: time.Unix(1700000000, 0)}
	ctx := context.Background()
	l := LockTake(ctx, ExecRunner{}, state, "", clock, 1234)
	if l == nil {
		t.Fatal("lock not taken")
	}
	if !fileExists(filepath.Join(state, "lock", "pid")) {
		t.Fatal("pid not written")
	}
	// second take fails (lock held)
	l2 := LockTake(ctx, ExecRunner{}, state, "", clock, 5678)
	if l2 != nil {
		t.Fatal("second took lock")
	}
	l.LockRelease()
	if fileExists(filepath.Join(state, "lock")) {
		t.Fatal("lock not released")
	}
}

func TestLockOrphanPurge(t *testing.T) {
	state := t.TempDir()
	lockDir := filepath.Join(state, "lock")
	os.Mkdir(lockDir, 0o755)
	os.WriteFile(filepath.Join(lockDir, "pid"), []byte("999999"), 0o644)
	// age it 60 s
	old := time.Now().Add(-60 * time.Second)
	os.Chtimes(lockDir, old, old)
	clock := &FakeClock{NowTime: time.Now()}
	l := LockTake(context.Background(), ExecRunner{}, state, "", clock, 1)
	if l == nil {
		t.Fatal("orphan not purged")
	}
	l.LockRelease()
}

func TestRankTakeAdvance(t *testing.T) {
	state := t.TempDir()
	clock := &FakeClock{NowTime: time.Unix(1700000000, 0)}
	journal := filepath.Join(state, "j.log")
	excluded := func(string) bool { return true }
	start, ok := RankTake(context.Background(), ExecRunner{}, state, journal, clock, 1, 9, nil, excluded)
	if !ok || start != 0 {
		t.Fatal("start", start, ok)
	}
	// rank advanced when no requested model available
	data, _ := os.ReadFile(filepath.Join(state, "rang"))
	n, _ := strconv.Atoi(trimRight(string(data)))
	if n != 1 {
		t.Fatal("rang not 1", string(data))
	}
	j := readFileString(journal)
	if !containsStr(j, "=== rank 1/9") {
		t.Fatal("no rank line", j)
	}
}

func TestRankNotAdvanceWhenRequestedAvailable(t *testing.T) {
	state := t.TempDir()
	clock := &FakeClock{NowTime: time.Unix(1700000000, 0)}
	excluded := func(m string) bool { return false }
	RankTake(context.Background(), ExecRunner{}, state, "", clock, 1, 9, []string{"hy4-flash-free"}, excluded)
	if fileExists(filepath.Join(state, "rang")) {
		t.Fatal("rank advanced when requested available")
	}
}
