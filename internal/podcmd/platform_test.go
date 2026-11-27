package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

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
