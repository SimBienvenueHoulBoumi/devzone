package e2e

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// fakeClock advances on sleep, so a timeout test never waits in real time.
type fakeClock struct {
	t time.Time
}

func (c *fakeClock) now() time.Time        { return c.t }
func (c *fakeClock) sleep(d time.Duration) { c.t = c.t.Add(d) }

// fixture holds the fakes of one e2e test, with no real tool or network.
type fixture struct {
	t        *testing.T
	r        *fake.Runner
	clock    *fakeClock
	root     string
	home     string
	hosts    string
	tmp      string
	clones   string
	platform string
	repow    string
	out      strings.Builder
	err      strings.Builder
	server   *httptest.Server
	mu       sync.Mutex
	apiCalls []string
	pipeRuns int
	pipeBody string
	keyBody  string
	failGit  string
	hook     func(string, []string)
}

// newFixture builds an isolated root and fakes every tool of the steps.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	f := &fixture{t: t, r: fake.New(), clock: &fakeClock{t: time.Unix(0, 0)}, root: root,
		home: filepath.Join(root, "home"), tmp: filepath.Join(root, "tmp")}
	f.clones, f.platform, f.repow = filepath.Join(f.tmp, "clones"),
		filepath.Join(f.tmp, "plateforme"), filepath.Join(f.tmp, "repowarden")
	for _, dir := range []string{f.home, f.tmp, f.clones, f.platform,
		filepath.Join(f.repow, "repowarden", "test", "gitlab"), filepath.Join(f.root, "workspace", ".gitlab")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	secrets := filepath.Join(f.root, "workspace", ".gitlab")
	f.write(filepath.Join(secrets, "root-token"), "token-root-secret\n")
	f.hosts = filepath.Join(f.root, "hosts")
	f.write(f.hosts, "127.0.0.1 localhost\n127.0.0.1\tgitlab.localhost # devzone:gitlab\n")
	f.write(filepath.Join(f.root, ".devzone.modules"), "")
	f.write(filepath.Join(f.clones, "id_ed25519.pub"), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@devzone\n")
	for key, value := range map[string]string{
		"DEVZONE_ROOT": root, "DEVZONE_STATE": filepath.Join(root, ".devzone.modules"),
		"DEVZONE_HOSTS": f.hosts, "DEVZONE_INSTANCE": "", "DEVZONE_TEST_DEVZONE": "", "TMPDIR": f.tmp,
		"GITLAB_TEST_PIPELINE": "2", "GITLAB_TEST_INTERVALLE": "1", "REPOWARDEN_TEST_REF": "develop",
	} {
		t.Setenv(key, value)
	}
	f.programRunner()
	f.programServer()
	return f
}

// write creates a file of the fixture with restricted rights.
func (f *fixture) write(path, content string) {
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// programRunner answers every command of the steps; the fakes record calls.
func (f *fixture) programRunner() {
	r := f.r
	name := scriptName()
	r.On(name, nil, exec.Result{})
	r.On(name, []string{"is-enabled", "gitlab"}, exec.Result{})
	r.On(name, []string{"gitlab", "status"}, exec.Result{Stdout: []byte("ready: http://gitlab.localhost:8929, runner online\n")})
	r.On("getent", []string{"hosts", "gitlab.localhost"}, exec.Result{Stdout: []byte("127.0.0.1 gitlab.localhost\n")})
	r.On(name, []string{"gitlab", "relay-status"}, exec.Result{Stdout: []byte("gitlab relay online\n")})
	r.On(name, []string{"platform", "gitlab"}, exec.Result{})
	r.On(name, []string{"platform", "github"}, exec.Result{})
	r.On("kubectl", nil, exec.Result{Code: 1})
	r.On(filepath.Join(f.home, ".local", "bin", "glab"), nil, exec.Result{})
	r.On("ssh-keygen", nil, exec.Result{})
	r.On("git", nil, exec.Result{})
	r.On("bats", nil, exec.Result{})
	r.On("gh", []string{"auth", "status"}, exec.Result{})
	r.On("gh", []string{"repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"},
		exec.Result{Stdout: []byte("SimBienvenueHoulBoumi/devzone\n")})
	r.On("git", []string{"rev-parse", "HEAD"}, exec.Result{Stdout: []byte("0123456789abcdef\n")})
	r.On("gh", nil, exec.Result{})
}

// scriptName is the path of the fake devzone used by the steps, when set.
func scriptName() string {
	if name := os.Getenv("DEVZONE_TEST_DEVZONE"); name != "" {
		return name
	}
	return "devzone"
}

// programServer answers the API calls of the steps on a local server.
func (f *fixture) programServer() {
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		f.mu.Lock()
		f.apiCalls = append(f.apiCalls, req.Method+" "+req.URL.Path)
		pipeBody, keyBody := f.pipeBody, f.keyBody
		f.mu.Unlock()
		if req.Header.Get("PRIVATE-TOKEN") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		code, body := http.StatusOK, `{"id":42}`
		switch {
		case strings.HasSuffix(req.URL.Path, "/pipeline"):
			if pipeBody == "fail" {
				code = http.StatusInternalServerError
			} else {
				body = `{"id":42,"web_url":"http://gitlab.localhost:8929/devzone/demo/-/pipelines/42"}`
			}
		case strings.Contains(req.URL.Path, "/pipelines/42"):
			f.mu.Lock()
			f.pipeRuns++
			n := f.pipeRuns
			f.mu.Unlock()
			state := "running"
			if pipeBody == "failed" {
				state = "failed"
			} else if pipeBody == "success" || (pipeBody == "" && n > 1) {
				state = "success"
			}
			body = fmt.Sprintf(`{"status":%q}`, state)
		case req.URL.Path == "/api/v4/user/keys":
			if keyBody == "fail" {
				code = http.StatusInternalServerError
			} else {
				body = `{"id":7}`
			}
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	}))
	f.t.Cleanup(f.server.Close)
}

// opts returns the options of the fixture, with the injected clock and temp
// folder so that a run never waits or calls a real tool.
func (f *fixture) opts() Options {
	return Options{
		Runner:    &commandRunner{Runner: f.r, f: f},
		Out:       &f.out,
		Err:       &f.err,
		Root:      f.root,
		Home:      f.home,
		URL:       f.server.URL,
		Now:       f.clock.now,
		Sleep:     f.clock.sleep,
		MkdirTemp: f.mkdirTemp,
	}
}

// mkdirTemp returns fixed folders so the tests can prepare their content.
func (f *fixture) mkdirTemp(prefix string) (string, error) {
	switch {
	case strings.Contains(prefix, "clones"):
		return f.clones, nil
	case strings.Contains(prefix, "plateforme"):
		return f.platform, nil
	default:
		return f.repow, nil
	}
}

// run runs the command line and returns its status.
func (f *fixture) run(args ...string) int {
	f.out.Reset()
	f.err.Reset()
	return Run(context.Background(), args, f.opts())
}

// calls returns the recorded commands as "name arg..." lines.
func (f *fixture) calls() []string {
	var out []string
	for _, c := range f.r.Calls() {
		out = append(out, c.Name+" "+strings.Join(c.Args, " "))
	}
	return out
}

// hasCall reports whether a recorded command contains all the words of a line.
func (f *fixture) hasCall(line string) bool {
	for _, c := range f.r.Calls() {
		args := append([]string{c.Name}, c.Args...)
		if containsWords(strings.Join(args, " "), line) {
			return true
		}
	}
	return false
}

// containsWords reports whether every word of line is present in text.
func containsWords(text, line string) bool {
	for _, word := range strings.Fields(line) {
		if !strings.Contains(text, word) {
			return false
		}
	}
	return true
}

// execResultCode builds a runner answer with the given exit status.
func execResultCode(code int) exec.Result { return exec.Result{Code: code} }

// execResultOut builds a successful runner answer with the given output.
func execResultOut(text string) exec.Result { return exec.Result{Stdout: []byte(text)} }

// commandRunner injects failures of a chosen git clone.
type commandRunner struct {
	*fake.Runner
	f *fixture
}

func (c *commandRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if c.f.hook != nil {
		c.f.hook(name, args)
	}
	if name == "git" && c.f.failGit != "" && strings.Contains(strings.Join(args, " "), c.f.failGit) {
		return exec.Result{Code: 1}, nil
	}
	return c.Runner.Run(ctx, name, args, opts)
}
