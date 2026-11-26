package gitlab

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// realDemoDir returns the real demo folder of the repository, as the seed of
// the installation pushes it to the demo project of the instance.
func realDemoDir() string {
	return "../../../.devcontainer/gitlab/demo"
}

// demoEntries are the files of the real demo folder, checked for presence and
// for content in the copy of the folder.
var demoEntries = []string{
	".gitlab-ci.yml",
	"pyproject.toml",
	"src/calc/__init__.py",
	"tests/test_calc.py",
}

// TestCopyDirRealDemo checks the copy of the real demo folder of the
// repository, subfolders and hidden files included: the copy used to stop on
// the subfolder before the fix.
func TestCopyDirRealDemo(t *testing.T) {
	tmpdir := t.TempDir()
	if err := copyDir(realDemoDir(), tmpdir); err != nil {
		t.Fatalf("copy of the real demo folder failed: %v", err)
	}
	for _, rel := range demoEntries {
		if _, err := os.Stat(filepath.Join(tmpdir, filepath.FromSlash(rel))); err != nil {
			t.Errorf("the copy of the real demo folder lacks %q: %v", rel, err)
		}
	}
	for _, rel := range demoEntries {
		src := filepath.Join(realDemoDir(), filepath.FromSlash(rel))
		dst := filepath.Join(tmpdir, filepath.FromSlash(rel))
		want, err := os.ReadFile(src)
		if err != nil {
			t.Errorf("read of %q failed: %v", rel, err)
			continue
		}
		got, err := os.ReadFile(dst)
		if err != nil {
			t.Errorf("read of the copy of %q failed: %v", rel, err)
			continue
		}
		if string(got) != string(want) {
			t.Errorf("content of the copy of %q = %q, want %q", rel, got, want)
		}
	}
}

// TestCopyDirKeepsModes checks the copy of a tree with a subfolder, a hidden
// file and an executable file: the mode of the executable is preserved, like
// the cp -r of the old seed did.
func TestCopyDirKeepsModes(t *testing.T) {
	src := t.TempDir()
	if err := os.MkdirAll(src+"/scripts", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src+"/scripts/run.sh", []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src+"/.hidden", []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	if err := copyDir(src, dst); err != nil {
		t.Fatalf("copy of the tree failed: %v", err)
	}
	info, err := os.Stat(dst + "/scripts/run.sh")
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o755 {
		t.Errorf("mode of scripts/run.sh = %o, want 755", perm)
	}
	data, err := os.ReadFile(dst + "/scripts/run.sh")
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "#!/bin/sh\n" {
		t.Errorf("content of scripts/run.sh = %q", data)
	}
	data, err = os.ReadFile(dst + "/.hidden")
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "x\n" {
		t.Errorf("content of .hidden = %q", data)
	}
}

// TestSeedDemoPushRealDemo checks the full seed on a copy of the real demo
// folder of the repository: the push of the demo project goes through the copy
// of the demo and reaches the check of the branch (the seed used to stop on the
// subfolder of the demo before the fix).
func TestSeedDemoPushRealDemo(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("git", nil, exec.Result{})
	var mu sync.Mutex
	branchChecks := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/repository/branches/main"):
			mu.Lock()
			defer mu.Unlock()
			branchChecks++
			if branchChecks == 1 {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"name":"main"}`))
		case strings.HasSuffix(r.URL.Path, "user/runners"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"token":"token-runner-secret"}`))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id":42}`))
		}
	}))
	t.Cleanup(srv.Close)
	testBaseURL = srv.URL
	t.Cleanup(func() { testBaseURL = "" })

	demoDir := filepath.Join(f.root, ".devcontainer", "gitlab", "demo")
	if err := os.MkdirAll(demoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := copyDir(realDemoDir(), demoDir); err != nil {
		t.Fatalf("copy of the real demo folder failed: %v", err)
	}
	if code := f.run("seed"); code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	if !strings.Contains(f.outStr(), "✔ GitLab seed complete.") {
		t.Errorf("output = %q", f.outStr())
	}
	pushedCall := false
	for _, c := range f.r.Calls() {
		if c.Name != "git" {
			continue
		}
		for _, arg := range c.Args {
			if arg == "push" {
				pushedCall = true
			}
		}
	}
	if !pushedCall {
		t.Errorf("no push of the demo project in %v", f.calls())
	}
}
