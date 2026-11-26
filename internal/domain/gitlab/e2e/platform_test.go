package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestE2EPlatformFailures checks step 6: a failed platform change, and a
// failed glab clone that still restores the previous platform.
func TestE2EPlatformFailures(t *testing.T) {
	t.Run("platform", func(t *testing.T) {
		f := newFixture(t)
		f.r.On(scriptName(), []string{"platform", "gitlab"}, execResultCode(1))
		if code := f.run(); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		for _, want := range []string{"✖ 6. platform", "devzone platform gitlab failed"} {
			if !strings.Contains(f.out.String(), want) {
				t.Errorf("output lacks %q: %s", want, f.out.String())
			}
		}
	})
	t.Run("glab clone", func(t *testing.T) {
		f := newFixture(t)
		glab := filepath.Join(f.home, ".local", "bin", "glab")
		f.r.On(glab, nil, execResultCode(1))
		if code := f.run(); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		for _, want := range []string{"✖ 6. platform", "glab repo clone devzone/demo failed"} {
			if !strings.Contains(f.out.String(), want) {
				t.Errorf("output lacks %q: %s", want, f.out.String())
			}
		}
		if !f.hasCall("platform github") {
			t.Errorf("platform not restored: %v", f.calls())
		}
		if exists(glab) || exists(filepath.Join(f.home, ".config", "glab-cli")) {
			t.Error("glab or its configuration remains")
		}
	})
}

// TestE2ERepowardenFailures checks step 7: clone failure, failed suite with a
// masked log, and a missing suite that is skipped without failing the run.
func TestE2ERepowardenFailures(t *testing.T) {
	t.Run("clone", func(t *testing.T) {
		f := newFixture(t)
		f.failGit = "repowarden"
		if code := f.run(); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		for _, want := range []string{"✖ 7. repowarden integration", "clone of repowarden (ref develop) impossible"} {
			if !strings.Contains(f.out.String(), want) {
				t.Errorf("output lacks %q: %s", want, f.out.String())
			}
		}
	})
	t.Run("suite", func(t *testing.T) {
		f := newFixture(t)
		f.r.On("bats", nil, exec.Result{Stdout: []byte("suite failed with token token-root-secret\n"), Code: 1})
		if code := f.run(); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		for _, want := range []string{"✖ 7. repowarden integration", "the test/gitlab suite failed"} {
			if !strings.Contains(f.out.String(), want) {
				t.Errorf("output lacks %q: %s", want, f.out.String())
			}
		}
		log, err := os.ReadFile(filepath.Join(f.tmp, "devzone-test-gitlab-repowarden.log"))
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(log), "TOKEN_MASKED") || strings.Contains(string(log), "token-root-secret") {
			t.Errorf("log = %q", log)
		}
	})
	t.Run("skipped", func(t *testing.T) {
		f := newFixture(t)
		if err := os.RemoveAll(filepath.Join(f.repow, "repowarden", "test", "gitlab")); err != nil {
			t.Fatal(err)
		}
		if code := f.run(); code != 0 {
			t.Fatalf("code = %d, want 0 when the suite is absent", code)
		}
		if !strings.Contains(f.out.String(), "– 7. repowarden integration") ||
			!strings.Contains(f.out.String(), "skipped: test/gitlab missing at ref develop") {
			t.Errorf("output = %q", f.out.String())
		}
	})
}

// TestE2EStatusPublish checks --statut: the GitHub status of HEAD is published
// with the short summary as description.
func TestE2EStatusPublish(t *testing.T) {
	f := newFixture(t)
	if code := f.run("--statut"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.err.String())
	}
	if !f.hasCall("api -X POST repos/SimBienvenueHoulBoumi/devzone/statuses/0123456789abcdef") ||
		!f.hasCall("context=gitlab-integration") || !f.hasCall("state=success") {
		t.Errorf("gh api call missing in %v", f.calls())
	}
	if !strings.Contains(f.out.String(), "gitlab-integration status (success) published") {
		t.Errorf("output = %q", f.out.String())
	}
}

// TestE2EStatusRefusals checks --statut on a failed run and without gh login.
func TestE2EStatusRefusals(t *testing.T) {
	t.Run("failure", func(t *testing.T) {
		f := newFixture(t)
		f.failGit = f.server.URL
		if code := f.run("--statut"); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		if !f.hasCall("state=failure") || !f.hasCall("context=gitlab-integration") {
			t.Errorf("gh api call missing in %v", f.calls())
		}
	})
	t.Run("no login", func(t *testing.T) {
		f := newFixture(t)
		f.r.On("gh", []string{"auth", "status"}, execResultCode(1))
		if code := f.run("--statut"); code == 0 {
			t.Fatal("code = 0, want failure")
		}
		if !strings.Contains(f.err.String(), "gh not logged in") {
			t.Errorf("stderr = %q", f.err.String())
		}
		for _, call := range f.calls() {
			if strings.Contains(call, "gh api") {
				t.Errorf("gh api called without login: %q", call)
			}
		}
	})
}
