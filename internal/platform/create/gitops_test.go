package create

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"io"
)

// ghConnectedRunner programs gh auth status ok and a login for gh api user.
func ghConnectedRunner(login string) *fake.Runner {
	r := fake.New()
	r.On("gh", []string{"auth", "status"}, fexec.Result{})
	r.On("gh", []string{"api", "user", "--jq", ".login"}, fexec.Result{Stdout: []byte(login + "\n")})
	return r
}

// TestGitopsGithubResolves checks github maps to a repo under the gh account,
// with DEVZONE_GITOPS_REPO_NAME and DEVZONE_VOLUMES applied.
func TestGitopsGithubResolves(t *testing.T) {
	opts := Options{Runner: ghConnectedRunner("alice"), Err: io.Discard}
	got := gitopsValue("github", opts)
	if got != "https://github.com/alice/devzone-argocd.git" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("DEVZONE_GITOPS_REPO_NAME", "mine")
	if got := gitopsValue("github", opts); got != "https://github.com/alice/mine.git" {
		t.Fatalf("repo name: %q", got)
	}
	t.Setenv("DEVZONE_VOLUMES", "prod")
	if got := gitopsValue("github", opts); got != "https://github.com/alice/mine-prod.git" {
		t.Fatalf("instance suffix: %q", got)
	}
}

// TestGitopsGithubNotConnected checks github falls back to none with a notice
// when gh is not connected or the login is unreadable.
func TestGitopsGithubNotConnected(t *testing.T) {
	var errOut strings.Builder
	opts := Options{Runner: fake.New(), Err: &errOut}
	if got := gitopsValue("github", opts); got != "none" {
		t.Fatalf("got %q", got)
	}
	if !strings.Contains(errOut.String(), "GitHub not connected") {
		t.Fatalf("stderr %q", errOut.String())
	}
	errOut.Reset()
	r := fake.New()
	r.On("gh", []string{"auth", "status"}, fexec.Result{})
	r.On("gh", []string{"api", "user", "--jq", ".login"}, fexec.Result{Stdout: []byte("\n")})
	opts.Runner = r
	if got := gitopsValue("github", opts); got != "none" {
		t.Fatalf("empty login: %q", got)
	}
	if !strings.Contains(errOut.String(), "GitHub login unreadable") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

// TestGitopsPassThrough checks none stays none and anything else is a URL.
func TestGitopsPassThrough(t *testing.T) {
	opts := Options{Runner: fake.New(), Err: io.Discard}
	if got := gitopsValue("none", opts); got != "none" {
		t.Fatalf("none: %q", got)
	}
	if got := gitopsValue("https://example.com/r.git", opts); got != "https://example.com/r.git" {
		t.Fatalf("url: %q", got)
	}
}

// TestAskGitops checks the interactive parsing: empty answer takes the
// default, G/y forms mean github, n forms mean none, anything else is a URL.
func TestAskGitops(t *testing.T) {
	r := ghConnectedRunner("alice")
	for _, c := range []struct {
		answer string
		want   string
	}{
		{"", "github"},       // default: gh connected
		{"G", "github"},      //
		{"g", "github"},      //
		{"GitHub", "github"}, //
		{"github", "github"}, //
		{"y", "github"},      //
		{"Y", "github"},      //
		{"yes", "github"},    //
		{"n", "none"},        //
		{"N", "none"},        //
		{"none", "none"},     //
		{"None", "none"},     //
		{"https://example.com/x.git", "https://example.com/x.git"}, // URL
		{"o", "o"}, //
	} {
		var errOut strings.Builder
		got := askGitops(strings.NewReader(c.answer+"\n"), &errOut, r, nil)
		if got != c.want {
			t.Fatalf("answer %q: got %q want %q", c.answer, got, c.want)
		}
		if !strings.Contains(errOut.String(), "GitOps repository for Argo CD?") {
			t.Fatalf("no prompt on stderr for %q", c.answer)
		}
	}
	// end of input with no gh: empty answer, no default
	got := askGitops(strings.NewReader(""), io.Discard, fake.New(), nil)
	if got != "" {
		t.Fatalf("EOF without gh: %q", got)
	}
}

// TestAskGitopsDefaultGithub checks an empty answer picks github when gh is
// connected, none otherwise.
func TestAskGitopsDefaultGithub(t *testing.T) {
	if got := askGitops(strings.NewReader("\n"), io.Discard, ghConnectedRunner("a"), nil); got != "github" {
		t.Fatalf("connected default: %q", got)
	}
	if got := askGitops(strings.NewReader("\n"), io.Discard, fake.New(), nil); got != "" {
		t.Fatalf("not connected default: %q", got)
	}
}
