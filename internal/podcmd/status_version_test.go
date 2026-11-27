package podcmd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestStatusPublishedVersion checks that the available-version line uses the
// daily cache and stays silent when the folder has no version.
func TestStatusPublishedVersion(t *testing.T) {
	t.Run("newer published version", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 0.19.0\n")
		contains(t, runStatusText(t, r), "  ○ devzone 3.2.2 available: on the workstation, devzone update")
	})
	for _, folder := range []string{"3.2.2", "4.0.0"} {
		t.Run("not newer "+folder, func(t *testing.T) {
			root, _, _, r := statusFixture(t)
			writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version "+folder+"\n")
			if strings.Contains(runStatusText(t, r), "available: on the workstation") {
				t.Fatalf("version %s must not be reported as outdated", folder)
			}
		})
	}
	t.Run("without folder version", func(t *testing.T) {
		_, _, _, r := statusFixture(t)
		if strings.Contains(runStatusText(t, r), "available: on the workstation") {
			t.Fatal("no version line without .devzone.version")
		}
	})
}

// TestStatusVersionCache checks that the registry is consulted at most once a
// day, and that an unavailable registry leaves the summary usable.
func TestStatusVersionCache(t *testing.T) {
	t.Run("once a day", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 0.19.0\n")
		cache := filepath.Join(os.Getenv("HOME"), ".cache", "devzone", "version-publiee")
		if err := os.Remove(cache); err != nil {
			t.Fatal(err)
		}
		r.program(nil, 0, "0.20.0\n", "npm", "view", "devzone", "version")
		contains(t, runStatusText(t, r), "  ○ devzone 0.20.0 available")
		contains(t, runStatusText(t, r), "  ○ devzone 0.20.0 available")
	})
	t.Run("offline", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 0.19.0\n")
		cache := filepath.Join(os.Getenv("HOME"), ".cache", "devzone", "version-publiee")
		if err := os.Remove(cache); err != nil {
			t.Fatal(err)
		}
		r.program(nil, 1, "", "npm", "view", "devzone", "version")
		if strings.Contains(runStatusText(t, r), "available: on the workstation") {
			t.Fatal("an offline registry must stay silent")
		}
		if _, err := os.Stat(cache); err != nil {
			t.Fatalf("cache not written: %v", err)
		}
	})
}

// deadlineRunner records the context deadline given to the version lookup and
// returns immediately, so the test never waits for a slow registry.
type deadlineRunner struct {
	inner    stubRunner
	called   bool
	deadline bool
}

// Run implements exec.Runner and observes the deadline of the npm lookup.
func (r *deadlineRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if name == "npm" {
		r.called = true
		_, r.deadline = ctx.Deadline()
		return exec.Result{}, nil
	}
	return r.inner.Run(ctx, name, args, opts)
}

// TestStatusVersionTimeout checks that the version lookup is bounded by a
// deadline, as the five-second wait of the removed shell status.
func TestStatusVersionTimeout(t *testing.T) {
	root, _, _, stub := statusFixture(t)
	writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 0.19.0\n")
	cache := filepath.Join(os.Getenv("HOME"), ".cache", "devzone", "version-publiee")
	if err := os.Remove(cache); err != nil {
		t.Fatal(err)
	}
	r := &deadlineRunner{inner: stub}
	runStatusWithRunner(t, r)
	if !r.called || !r.deadline {
		t.Fatalf("version lookup: called %v, deadline %v", r.called, r.deadline)
	}
}

// TestStatusJSON checks that status --json reaches the Go JSON status instead
// of starting a shell command.
func TestStatusJSON(t *testing.T) {
	root, code, stateFile := jsonFixture(t)
	writeJSONFile(t, stateFile, "")
	r := stubRunner{t: t, responses: map[string]exec.Result{}}
	r.program(nil, 0, "", "git", "config", "--get", "user.name")
	r.program(nil, 0, "", "git", "config", "--get", "user.email")
	r.program(nil, 1, "", "gh", "auth", "status")
	r.program(nil, 0, "", "bash", filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "--installees")
	r.program(nil, 0, "", "kubectl", "config", "current-context")
	r.program(nil, 0, "", "devzone", "cluster", "clean", "--quiet")
	r.program(nil, 0, "[]\n", "devzone", "port", "list", "--json")
	r.program(nil, 0, "[]\n", "bash", filepath.Join(code, "catalog.sh"), "json")
	r.program(nil, 0, "", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")
	out := runStatusWithRunner(t, r, "--json")
	contains(t, out, "{\n  \"schema\": 3,", "\"git_identity\": {")
}
