package podcmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// scriptRunner replaces the external commands of the platform: it records each
// call ("name arg…") and whether the output was inherited, and answers with
// respond (a success with no output when respond is nil).
type scriptRunner struct {
	calls     []string
	inherited []bool
	respond   func(name string, args []string) (fexec.Result, error)
}

func (r *scriptRunner) Run(_ context.Context, name string, args []string, opts fexec.Opts) (fexec.Result, error) {
	r.calls = append(r.calls, strings.Join(append([]string{name}, args...), " "))
	r.inherited = append(r.inherited, opts.Inherit)
	if r.respond != nil {
		return r.respond(name, args)
	}
	return fexec.Result{}, nil
}

// called reports whether a command with this line was run.
func (r *scriptRunner) called(line string) bool {
	for _, c := range r.calls {
		if c == line {
			return true
		}
	}
	return false
}

// platformFixture is a devzone folder and a home for the platform commands,
// with the Runner above and an empty state file.
type platformFixture struct {
	p      *platformCmd
	out    *bytes.Buffer
	errOut *bytes.Buffer
	run    *scriptRunner
	root   string
	home   string
}

func newPlatformFixture(t *testing.T, stateLines ...string) *platformFixture {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "home")
	etat := filepath.Join(root, ".devzone.modules")
	if err := os.WriteFile(etat, []byte(strings.Join(stateLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	run := &scriptRunner{}
	ctx := &cli.Context{Out: out, Err: errOut, Stdin: strings.NewReader(""), Runner: run}
	m := &modules{ctx: ctx, etat: etat, root: root, code: root, home: home}
	p := &platformCmd{
		m:    m,
		glab: filepath.Join(home, ".local", "bin", "glab"),
		arch: "amd64",
		sum:  "",
	}
	return &platformFixture{p: p, out: out, errOut: errOut, run: run, root: root, home: home}
}

// installFakeGlab creates the glab binary at its path, as an earlier install did.
func (f *platformFixture) installFakeGlab(t *testing.T) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(f.p.glab), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.p.glab, []byte("glab"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// state returns the content of the state file.
func (f *platformFixture) state(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.p.m.etat)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// argAfter returns the argument that follows flag in args, "" when absent.
func argAfter(args []string, flag string) string {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag {
			return args[i+1]
		}
	}
	return ""
}

// fakeArchive makes a Runner whose curl writes body to the -o file, whose
// sha256sum reports sum, and whose tar extracts a glab binary when extract is set.
func fakeArchive(body []byte, sum string, extract bool) func(name string, args []string) (fexec.Result, error) {
	return func(name string, args []string) (fexec.Result, error) {
		switch name {
		case "curl":
			if err := os.WriteFile(argAfter(args, "-o"), body, 0o644); err != nil {
				return fexec.Result{Code: 1}, nil
			}
		case "sha256sum":
			return fexec.Result{Stdout: []byte(sum + "  " + args[0] + "\n")}, nil
		case "tar":
			if extract {
				folder := argAfter(args, "-C")
				bin := filepath.Join(folder, "bin")
				if err := os.MkdirAll(bin, 0o755); err != nil {
					return fexec.Result{Code: 1}, nil
				}
				if err := os.WriteFile(filepath.Join(bin, "glab"), []byte("glab"), 0o755); err != nil {
					return fexec.Result{Code: 1}, nil
				}
			}
		}
		return fexec.Result{}, nil
	}
}

// bodySum returns the SHA-256 sum of body, in hexadecimal.
func bodySum(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
