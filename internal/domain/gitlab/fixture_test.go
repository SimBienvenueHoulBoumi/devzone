package gitlab

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// fakeClock advances on sleep: a pipeline or readiness timeout is tested
// without waiting, and no test depends on the wall clock.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time        { return c.t }
func (c *fakeClock) sleep(d time.Duration) { c.t = c.t.Add(d) }

// fixture holds the fake runner and the state of one gitlab test.
type fixture struct {
	r        *fake.Runner
	root     string
	out      strings.Builder
	err      strings.Builder
	tb       testing.TB
	alivePid string
	relays   []string
	clock    *fakeClock
}

// newFixture creates an isolated devzone root with a fake runner and sets the
// environment of the module (DEVZONE_ROOT, DEVZONE_STATE, DEVZONE_HOSTS, ...).
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_HOSTS", filepath.Join(root, "hosts"))
	t.Setenv("DEVZONE_INSTANCE", "")
	t.Setenv("DEVZONE_INTERACTIVE", "")
	t.Setenv("GITLAB_ATTENTE", "1")
	f := &fixture{r: fake.New(), root: root, tb: t, clock: &fakeClock{t: time.Unix(0, 0)}}
	f.fakeBin()
	return f
}

// fakeBin prepends a bin folder with the fake tools to PATH: setsid, nohup,
// kill and pgrep, like the fakes of the bats tests.
func (f *fixture) fakeBin() {
	dir := filepath.Join(f.root, "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.tb.Fatal(err)
	}
	tools := map[string]string{
		"setsid": "#!/usr/bin/env bash\necho \"setsid $*\" >>\"$BIN_LOG\"\nexit 0\n",
		"nohup":  "#!/usr/bin/env bash\nexit 0\n",
		"kill":   "#!/usr/bin/env bash\ncase \"$1\" in -0) exit 0 ;; *) echo \"kill $*\" >>\"$BIN_LOG\" ;; esac\n",
		"pgrep":  "#!/usr/bin/env bash\nexit 1\n",
	}
	for name, script := range tools {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			f.tb.Fatal(err)
		}
	}
	t := f.tb
	t.Setenv("BIN_LOG", filepath.Join(f.root, "bin.log"))
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
}

// opts returns the Options of the run of the fixture.
func (f *fixture) opts() Options {
	return Options{
		Runner: f.r, Out: &f.out, Err: &f.err, Root: f.root,
		ProcessAlive: func(pid string) bool { return pid != "" && pid == f.alivePid },
		Now:          f.clock.now,
		Sleep:        f.clock.sleep,
		StartRelay: func(name, dir string, args []string) (string, error) {
			f.relays = append(f.relays, name+": "+strings.Join(args, " "))
			return "111111", nil
		},
	}
}

// run runs the gitlab command line and returns the exit status.
func (f *fixture) run(args ...string) int {
	return Run(context.Background(), args, f.opts())
}

// outStr returns the standard output of the last run.
func (f *fixture) outStr() string { return f.out.String() }

// errStr returns the standard error of the last run.
func (f *fixture) errStr() string { return f.err.String() }

// calls returns the recorded calls as "name args..." lines.
func (f *fixture) calls() []string {
	var out []string
	for _, c := range f.r.Calls() {
		out = append(out, c.Name+" "+strings.Join(c.Args, " "))
	}
	return out
}

// reset clears the recorded calls and the outputs of the run.
func (f *fixture) reset() {
	f.r = fake.New()
	f.out.Reset()
	f.err.Reset()
}

// secretsDir returns the secret folder of the root.
func (f *fixture) secretsDir() string { return filepath.Join(f.root, "workspace", ".gitlab") }

// writeFile writes a file of the root (0o600 for secrets).
func (f *fixture) writeFile(rel, content string) {
	path := filepath.Join(f.root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.tb.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		f.tb.Fatal(err)
	}
}

// modeOf returns the permission bits of a file of the root as octal digits
// ("600"), "" when missing.
func (f *fixture) modeOf(rel string) string {
	info, err := os.Stat(filepath.Join(f.root, rel))
	if err != nil {
		return ""
	}
	return strconv.FormatInt(int64(info.Mode().Perm()), 8)
}

// readFile returns the content of a file of the root, "" when missing.
func (f *fixture) readFile(rel string) string {
	data, err := os.ReadFile(filepath.Join(f.root, rel))
	if err != nil {
		return ""
	}
	return string(data)
}

// hasCall reports whether one of the recorded calls matches all the words of
// the line.
func (f *fixture) hasCall(line string) bool {
	for _, c := range f.r.Calls() {
		args := append([]string{c.Name}, c.Args...)
		if containsAll(strings.Join(args, " "), line) {
			return true
		}
	}
	return false
}

// containsAll reports whether s contains every word of the line.
func containsAll(s, line string) bool {
	for _, w := range strings.Fields(line) {
		if !strings.Contains(s, w) {
			return false
		}
	}
	return true
}

// stdout of a call is returned by the fake runner: program it with f.r.On.
var _ = exec.Result{}
