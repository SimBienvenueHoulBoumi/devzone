package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

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
	if code := f.p.connectGlab("gitlab.localhost:8929", gitlabURLModule()); code != 1 {
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
	if code := f.p.connectGlab("gitlab.localhost:8929", gitlabURLModule()); code != 0 {
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
