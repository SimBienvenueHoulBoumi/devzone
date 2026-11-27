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

// TestPlatformSummaryDefault checks the default platform: GitHub, with no state line.
func TestPlatformSummaryDefault(t *testing.T) {
	f := newPlatformFixture(t)
	if code := f.p.platformSummary(); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.out.String() != "devzone : github platform (default)\n" {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestPlatformSummaryGitLabNotConnected checks the summary of a GitLab platform
// whose glab is missing: the login command is given with the host.
func TestPlatformSummaryGitLabNotConnected(t *testing.T) {
	f := newPlatformFixture(t, "platform=gitlab", "gitlab_url=http://gitlab.example:8443")
	f.p.platformSummary()
	want := "devzone : gitlab platform: http://gitlab.example:8443, glab not connected: glab auth login --hostname gitlab.example:8443\n"
	if f.out.String() != want {
		t.Fatalf("stdout = %q, want %q", f.out.String(), want)
	}
}

// TestPlatformSummaryGitLabConnected checks the summary once glab is connected.
func TestPlatformSummaryGitLabConnected(t *testing.T) {
	f := newPlatformFixture(t, "platform=gitlab", "gitlab_url=http://gitlab.example:8443")
	f.installFakeGlab(t)
	f.p.platformSummary()
	if f.out.String() != "devzone : gitlab platform: http://gitlab.example:8443, glab connected\n" {
		t.Fatalf("stdout = %q", f.out.String())
	}
	if !f.run.called(f.p.glab + " auth status --hostname gitlab.example:8443") {
		t.Fatalf("status not checked: %v", f.run.calls)
	}
}

// TestPlatformGitHubRemovesGitLab checks the way back to GitHub: the credential
// setting of the instance goes, glab and its configuration are removed, the
// state keys leave.
func TestPlatformGitHubRemovesGitLab(t *testing.T) {
	f := newPlatformFixture(t, "platform=gitlab", "gitlab_url=http://gitlab.example:8443", "ai=on")
	f.installFakeGlab(t)
	cfg := filepath.Join(f.home, ".config", "glab-cli")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if code := f.p.changePlatform([]string{"github"}); code != 0 {
		t.Fatalf("code %d, stderr %q", code, f.errOut.String())
	}
	if !f.run.called("git config --global --unset-all credential.http://gitlab.example:8443.helper") {
		t.Fatalf("credential not unset: %v", f.run.calls)
	}
	if _, err := os.Stat(f.p.glab); !os.IsNotExist(err) {
		t.Fatalf("glab kept: %v", err)
	}
	if _, err := os.Stat(cfg); !os.IsNotExist(err) {
		t.Fatalf("glab configuration kept: %v", err)
	}
	if strings.Contains(f.state(t), "platform=") || strings.Contains(f.state(t), "gitlab_url=") || !strings.Contains(f.state(t), "ai=on") {
		t.Fatalf("state = %q", f.state(t))
	}
	if !strings.Contains(f.out.String(), "devzone : github platform (default)") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestPlatformGitLabArguments checks the refusals of the gitlab arguments.
func TestPlatformGitLabArguments(t *testing.T) {
	f := newPlatformFixture(t)
	if code := f.p.changePlatform([]string{"gitlab", "--bogus"}); code != 1 {
		t.Fatalf("unknown argument: code %d", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : unknown argument: --bogus (devzone platform gitlab --url URL)") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	f = newPlatformFixture(t)
	if code := f.p.changePlatform([]string{"gitlab", "--url"}); code != 1 {
		t.Fatalf("--url without value: code %d", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : --url expects a URL") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	f = newPlatformFixture(t)
	if code := f.p.changePlatform([]string{"gitlab"}); code != 1 {
		t.Fatalf("missing URL: code %d", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : missing URL: devzone platform gitlab --url URL") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestPlatformUnknownTarget checks the refusal of an unknown platform.
func TestPlatformUnknownTarget(t *testing.T) {
	f := newPlatformFixture(t)
	if code := f.p.changePlatform([]string{"forgejo"}); code != 1 {
		t.Fatalf("code %d", code)
	}
	want := "devzone : unknown platform: forgejo; choices: github (default) or gitlab [--url URL]\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
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

// TestInstallGlabSuccess checks the download, the sum check and the installation
// of the binary in the folder of the user.
func TestInstallGlabSuccess(t *testing.T) {
	f := newPlatformFixture(t)
	body := []byte("release archive")
	f.p.sum = bodySum(body)
	f.run.respond = fakeArchive(body, f.p.sum, true)
	if code := f.p.installGlab(); code != 0 {
		t.Fatalf("code %d, stderr %q", code, f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "devzone : downloading glab v1.126.0 (SHA-256 checked)…") {
		t.Fatalf("stdout = %q", f.out.String())
	}
	if !fileExists(f.p.glab) {
		t.Fatalf("glab not installed at %s", f.p.glab)
	}
}

// TestInstallGlabDownloadFailure checks the message and the status of a failed download.
func TestInstallGlabDownloadFailure(t *testing.T) {
	f := newPlatformFixture(t)
	f.run.respond = func(name string, _ []string) (fexec.Result, error) {
		if name == "curl" {
			return fexec.Result{Code: 22}, nil
		}
		return fexec.Result{}, nil
	}
	if code := f.p.installGlab(); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	want := "devzone : glab download failed (official gitlab.com release); retry: devzone platform gitlab --url URL\n"
	if f.errOut.String() != want || fileExists(f.p.glab) {
		t.Fatalf("stderr = %q, glab present %v", f.errOut.String(), fileExists(f.p.glab))
	}
}

// TestInstallGlabWrongSum checks that an archive with another sum is refused.
func TestInstallGlabWrongSum(t *testing.T) {
	f := newPlatformFixture(t)
	f.p.sum = bodySum([]byte("expected"))
	f.run.respond = fakeArchive([]byte("tampered"), bodySum([]byte("tampered")), true)
	if code := f.p.installGlab(); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : glab SHA-256 sum unexpected, aborting; archive refused") || fileExists(f.p.glab) {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestInstallGlabMissingBinary checks the refusal of an archive without glab.
func TestInstallGlabMissingBinary(t *testing.T) {
	f := newPlatformFixture(t)
	body := []byte("empty release")
	f.p.sum = bodySum(body)
	f.run.respond = fakeArchive(body, f.p.sum, false)
	if code := f.p.installGlab(); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : glab binary missing from the archive, aborting") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestInstallGlabAlreadyThere checks that nothing is downloaded when glab works.
func TestInstallGlabAlreadyThere(t *testing.T) {
	f := newPlatformFixture(t)
	f.installFakeGlab(t)
	if code := f.p.installGlab(); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.run.called("curl -fsSL -o") || len(f.run.calls) != 1 {
		t.Fatalf("calls %v", f.run.calls)
	}
}

// TestConnectGlabModuleNeedsToken checks that the gitlab module needs its root token.
func TestConnectGlabModuleNeedsToken(t *testing.T) {
	f := newPlatformFixture(t)
	if code := f.p.connectGlab("gitlab.localhost:8929", gitlabURLModule); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "root token of the gitlab module not found") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestConnectGlabModuleLogsIn checks the login with the root token, the token
// never printed, and the connection check.
func TestConnectGlabModuleLogsIn(t *testing.T) {
	f := newPlatformFixture(t)
	tokenDir := filepath.Join(f.root, "workspace", ".gitlab")
	if err := os.MkdirAll(tokenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tokenDir, "root-token"), []byte("tok-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := f.p.connectGlab("gitlab.localhost:8929", gitlabURLModule); code != 0 {
		t.Fatalf("code %d, stderr %q", code, f.errOut.String())
	}
	if !f.run.called(f.p.glab+" auth login --hostname gitlab.localhost:8929 --api-protocol http --git-protocol http --token tok-secret") &&
		!strings.Contains(strings.Join(f.run.calls, "\n"), "--token tok-secret") {
		t.Fatalf("login not called with the token: %v", f.run.calls)
	}
	if strings.Contains(f.out.String()+f.errOut.String(), "tok-secret") {
		t.Fatalf("token printed: %q %q", f.out.String(), f.errOut.String())
	}
	if !f.run.inherited[0] {
		t.Fatalf("login output not inherited")
	}
}

// TestConnectGlabOtherInstanceInteractive checks that another instance is logged
// in interactively, with the output inherited, and that a refusal is reported.
func TestConnectGlabOtherInstanceInteractive(t *testing.T) {
	f := newPlatformFixture(t)
	f.run.respond = func(_ string, args []string) (fexec.Result, error) {
		if len(args) > 1 && args[1] == "login" {
			return fexec.Result{Code: 1}, nil
		}
		return fexec.Result{}, nil
	}
	if code := f.p.connectGlab("git.example", "https://git.example"); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : cannot connect to the gitlab instance: glab auth login --hostname git.example") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if !f.run.inherited[0] {
		t.Fatalf("interactive login output not inherited")
	}
}

// TestChangeToGitLabSetsCredentialAndState checks the full switch to GitLab:
// glab connected, the git credential set for the instance, the state kept.
func TestChangeToGitLabSetsCredentialAndState(t *testing.T) {
	f := newPlatformFixture(t)
	f.installFakeGlab(t)
	if code := f.p.changePlatform([]string{"gitlab", "--url", "http://gitlab.example:8443"}); code != 0 {
		t.Fatalf("code %d, stderr %q", code, f.errOut.String())
	}
	if !f.run.called("git config --global credential.http://gitlab.example:8443.helper !" + f.p.glab + " auth git-credential") {
		t.Fatalf("credential not set: %v", f.run.calls)
	}
	if !strings.Contains(f.state(t), "platform=gitlab") || !strings.Contains(f.state(t), "gitlab_url=http://gitlab.example:8443") {
		t.Fatalf("state = %q", f.state(t))
	}
	if !strings.Contains(f.out.String(), "devzone : gitlab platform: http://gitlab.example:8443, glab connected") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestChangeToGitLabCredentialRefused checks that a refused credential setting
// keeps the platform unchanged.
func TestChangeToGitLabCredentialRefused(t *testing.T) {
	f := newPlatformFixture(t)
	f.installFakeGlab(t)
	f.run.respond = func(name string, args []string) (fexec.Result, error) {
		if name == "git" {
			return fexec.Result{Code: 1}, nil
		}
		return fexec.Result{}, nil
	}
	if code := f.p.changePlatform([]string{"gitlab", "--url", "http://gitlab.example:8443"}); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : cannot set the git credential") || strings.Contains(f.state(t), "platform=") {
		t.Fatalf("stderr %q, state %q", f.errOut.String(), f.state(t))
	}
}

// TestRunPlatformSummaryWithoutArguments checks that devzone platform alone shows the summary.
func TestRunPlatformSummaryWithoutArguments(t *testing.T) {
	root := t.TempDir()
	etat := filepath.Join(root, ".devzone.modules")
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", etat)
	if err := os.WriteFile(etat, []byte("ai=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &bytes.Buffer{}, Stdin: strings.NewReader(""), Runner: &scriptRunner{}}
	if code := runPlatform(ctx); code != 0 {
		t.Fatalf("code %d", code)
	}
	if out.String() != "devzone : github platform (default)\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}
