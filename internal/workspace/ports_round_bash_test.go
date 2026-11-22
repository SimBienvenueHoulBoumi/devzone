package workspace

import (
	"bytes"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// roundPair runs the same rounds with the bash original and with the Go code,
// on two state folders, and compares everything they do: the lines printed on
// both streams, the state files (names and contents, pids aside), the number
// of live relays and, at the end, every kubectl call.
type roundPair struct {
	t      *testing.T
	h      *roundHarness
	goDir  string
	shDir  string
	goLog  string
	shLog  string
	seeded map[string]map[int]bool
}

// newRoundPair skips when bash or the port test of the shell (lsof or nc) is
// missing, as the original would see every port free.
func newRoundPair(t *testing.T) *roundPair {
	t.Helper()
	h := newRoundHarness(t)
	_, lsof := exec.LookPath("lsof")
	_, nc := exec.LookPath("nc")
	if lsof != nil && nc != nil {
		t.Skip("neither lsof nor nc found: the shell cannot tell a port is taken")
	}
	p := &roundPair{t: t, h: h, goDir: h.stateDir("go"), shDir: h.stateDir("sh"), seeded: map[string]map[int]bool{}}
	p.goLog, p.shLog = filepath.Join(h.dir, "go.log"), filepath.Join(h.dir, "sh.log")
	return p
}

// seedLive records a live relay for port in both state folders, as an earlier round would.
func (p *roundPair) seedLive(port int) {
	for _, dir := range []string{p.goDir, p.shDir} {
		if p.seeded[dir] == nil {
			p.seeded[dir] = map[int]bool{}
		}
		p.seeded[dir][p.h.seedRelay(dir, port)] = true
	}
}

// bash runs one round of the original; max below the default is set after the
// script is sourced, as PA_MAX cannot be given from outside.
func (p *roundPair) bash(max int) (string, string) {
	script, err := filepath.Abs(filepath.FromSlash(portsScript))
	if err != nil {
		p.t.Fatal(err)
	}
	cmd := exec.Command("bash", script, "round")
	if max != appsMax {
		cmd = exec.Command("bash", "-c", `. "$1"; PA_MAX="$2"; pw_round`, "_", script, strconv.Itoa(max))
	}
	var out, errOut bytes.Buffer
	cmd.Dir, cmd.Stdout, cmd.Stderr = p.h.dir, &out, &errOut
	cmd.Env = append(os.Environ(), "LC_ALL=C", "DEVZONE_PORTS_WORKSPACE_REAL=yes",
		"DEVZONE_PORTS_WORKSPACE_DIR="+p.shDir, "FAKE_LOG="+p.shLog)
	if err := cmd.Run(); err != nil {
		p.t.Fatalf("bash round failed: %v\n%s%s", err, out.String(), errOut.String())
	}
	return out.String(), errOut.String()
}

// dump lists the state of dir, one line per entry, with the content of each
// file; a pid is shown as "seeded" or "new" because two runs never share one.
func (p *roundPair) dump(dir string) string {
	var lines []string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(dir, path)
		if err != nil || rel == "." {
			return nil
		}
		if d.IsDir() {
			lines = append(lines, rel+"/")
			return nil
		}
		data, _ := os.ReadFile(path)
		content := string(data)
		if strings.HasPrefix(rel, "relays"+string(filepath.Separator)) {
			pid, _ := strconv.Atoi(strings.TrimSpace(content))
			kind := "new"
			if p.seeded[dir][pid] {
				kind = "seeded"
			}
			content = kind + " pid, newline " + strconv.FormatBool(strings.HasSuffix(content, "\n"))
		}
		lines = append(lines, rel+" = "+strconv.Quote(content))
		return nil
	})
	return strings.Join(lines, "\n")
}

// step runs one round with the scenario in both implementations, fails on any
// difference and returns what the Go code printed.
func (p *roundPair) step(sc scenario, max int) (string, string) {
	p.t.Helper()
	p.h.use(sc, p.goLog)
	var out, errOut bytes.Buffer
	env := roundEnv{runner: ExecRunner{}, dir: p.goDir, modules: p.h.modules, taken: portTaken, start: startDetached, max: max, out: &out, errOut: &errOut}
	env.round()
	shOut, shErr := p.bash(max)
	if out.String() != shOut {
		p.t.Errorf("stdout differs\nbash: %q\nGo:   %q", shOut, out.String())
	}
	if errOut.String() != shErr {
		p.t.Errorf("stderr differs\nbash: %q\nGo:   %q", shErr, errOut.String())
	}
	if g, s := p.dump(p.goDir), p.dump(p.shDir); g != s {
		p.t.Errorf("state differs\nbash:\n%s\nGo:\n%s", s, g)
	}
	if g, s := liveRelays(p.goDir), liveRelays(p.shDir); g != s {
		p.t.Errorf("live relays: bash %d, Go %d", s, g)
	}
	return out.String(), errOut.String()
}

// sortedLog returns the lines of a kubectl log in order: port-forward lines are
// written by the relay itself, a moment after the round, so order is not compared.
func sortedLog(file string) string {
	lines := strings.Split(strings.TrimSpace(readAll(file)), "\n")
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

// finish checks that both implementations made the same kubectl calls, waiting
// a little for the port-forward lines of the relays.
func (p *roundPair) finish() {
	p.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for sortedLog(p.goLog) != sortedLog(p.shLog) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if g, s := sortedLog(p.goLog), sortedLog(p.shLog); g != s {
		p.t.Errorf("kubectl calls differ\nbash:\n%s\nGo:\n%s", s, g)
	}
}

// requirePortsFree skips the test when a fixed port of the modules is in use
// on this machine, because relays on it would not start.
func requirePortsFree(t *testing.T, ports ...int) {
	t.Helper()
	for _, port := range ports {
		if portTaken(port) {
			t.Skipf("port %d is in use on this machine", port)
		}
	}
}

// hasAll reports whether s holds all the parts.
func hasAll(s string, parts ...string) bool {
	for _, part := range parts {
		if !strings.Contains(s, part) {
			return false
		}
	}
	return true
}
