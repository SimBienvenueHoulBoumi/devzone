package podcmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// fakePod replaces the Go commands of the pod: it records each call ("name arg…")
// and answers with the scripted standard output and exit status. Unknown calls
// succeed with no output.
type fakePod struct {
	calls []string
	outs  map[string]string
	codes map[string]int
}

func (f *fakePod) run(out io.Writer, args ...string) int {
	key := strings.Join(args, " ")
	f.calls = append(f.calls, key)
	if s, ok := f.outs[key]; ok {
		_, _ = io.WriteString(out, s)
	}
	return f.codes[key]
}

// has reports whether the call was made.
func (f *fakePod) has(call string) bool {
	for _, c := range f.calls {
		if c == call {
			return true
		}
	}
	return false
}

// moduleFixture is a devzone folder for the module commands: the state file
// exists (so the state is never rebuilt), the Runner is a fake, the pod is fakePod.
type moduleFixture struct {
	m      *modules
	out    *bytes.Buffer
	errOut *bytes.Buffer
	pod    *fakePod
	root   string
}

// newModuleFixture builds the module commands on a state holding the given lines.
func newModuleFixture(t *testing.T, stateLines ...string) *moduleFixture {
	t.Helper()
	root := t.TempDir()
	etat := filepath.Join(root, ".devzone.modules")
	if err := os.WriteFile(etat, []byte(strings.Join(stateLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Out: out, Err: errOut, Stdin: strings.NewReader(""), Runner: fake.New()}
	pod := &fakePod{outs: map[string]string{}, codes: map[string]int{}}
	m := &modules{
		ctx:  ctx,
		etat: etat,
		root: root,
		code: root,
		home: filepath.Join(root, "home"),
		call: pod.run,
	}
	return &moduleFixture{m: m, out: out, errOut: errOut, pod: pod, root: root}
}

// state returns the content of the state file.
func (f *moduleFixture) state(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.m.etat)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// marker returns the content of the failure marker of a module, "" when absent.
func (f *moduleFixture) marker(module string) string {
	data, err := os.ReadFile(f.m.markerPath(module))
	if err != nil {
		return ""
	}
	return string(data)
}
