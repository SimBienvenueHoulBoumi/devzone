package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// startHarness holds the injected actions of one start scenario.
type startHarness struct {
	t      *testing.T
	env    StartEnv
	out    bytes.Buffer
	errOut bytes.Buffer
	calls  []string
	status int
}

// newStartHarness builds a start whose cluster is ready and whose actions are
// recorded instead of being run: no watcher, pod or cluster is touched.
func newStartHarness(t *testing.T) *startHarness {
	t.Helper()
	h := &startHarness{t: t, status: 0}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "package.json"), []byte(`{"version":"0.0.0"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	h.env = StartEnv{
		Modules: filepath.Join(t.TempDir(), ".devzone.modules"), Root: root,
		Out: &h.out, ErrOut: &h.errOut,
		Ready: func() (string, bool) { return "", true },
		Deploy: func(repository, tag string, withImage bool) int {
			h.calls = append(h.calls, "deploy "+repository+":"+tag+" "+boolText(withImage))
			return h.status
		},
		Wait:       func(image string) int { h.calls = append(h.calls, "wait "+image); return h.status },
		Guard:      func() { h.calls = append(h.calls, "guard") },
		PortsStart: func() { h.calls = append(h.calls, "ports") },
	}
	return h
}

// boolText records a bool in the call log.
func boolText(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

// TestStartDefault checks that a development clone deploys latest and that
// the wait, the guard and the watcher run in order after a successful deploy.
func TestStartDefault(t *testing.T) {
	h := newStartHarness(t)
	if status := h.env.Run(nil); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	want := "deploy " + imageRepo + ":latest no wait " + imageRepo + ":latest guard ports"
	if strings.Join(h.calls, " ") != want {
		t.Fatalf("calls = %q, want %q", h.calls, want)
	}
}

// TestStartImageOption checks the --image parsing and that a bad option does
// no deploy, no wait and no watcher start.
func TestStartImageOption(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"custom image", []string{"--image", "registry.example/mine:1.2.3"}, "deploy registry.example/mine:1.2.3 yes"},
		{"missing value", []string{"--image"}, "✖ option --image: provide an image"},
		{"no tag", []string{"--image", "repo"}, "✖ option --image: image has no tag"},
		{"unknown", []string{"--bogus"}, "✖ unknown option: --bogus"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newStartHarness(t)
			status := h.env.Run(tc.args)
			if strings.HasPrefix(tc.want, "✖") {
				if status != 1 || !strings.Contains(h.errOut.String(), tc.want) || len(h.calls) != 0 {
					t.Fatalf("status = %d, errOut = %q, calls = %q", status, h.errOut.String(), h.calls)
				}
				return
			}
			if status != 0 || !strings.Contains(strings.Join(h.calls, " "), tc.want) {
				t.Fatalf("status = %d, calls = %q, errOut = %q", status, h.calls, h.errOut.String())
			}
		})
	}
}

// TestStartStopsOnFailure checks that a failed deploy or wait does not start
// the guard or the watcher, so a broken start leaves no process behind.
func TestStartStopsOnFailure(t *testing.T) {
	for _, stage := range []string{"deploy", "wait"} {
		t.Run(stage, func(t *testing.T) {
			h := newStartHarness(t)
			if stage == "wait" {
				h.env.Deploy = func(string, string, bool) int {
					h.calls = append(h.calls, "deploy")
					return 0
				}
			}
			h.status = 4
			if status := h.env.Run(nil); status != 4 {
				t.Fatalf("status = %d, want 4", status)
			}
			for _, call := range h.calls {
				if call == "guard" || call == "ports" {
					t.Fatalf("%s ran after a failed %s: %q", call, stage, h.calls)
				}
			}
		})
	}
}

// TestArgoCDWantedAndInstalled checks the two conditions that keep the
// Argo CD forms of start and services delegated to the shell.
func TestArgoCDWantedAndInstalled(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".devzone.modules")
	for _, tc := range []struct {
		content string
		want    bool
	}{
		{"", true}, {"argocd=on\n", true}, {"argocd=off\n", false}, {"argocd=Off\n", true},
	} {
		if err := os.WriteFile(path, []byte(tc.content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := ArgoCDWanted(path); got != tc.want {
			t.Fatalf("modules %q: wanted = %v, want %v", tc.content, got, tc.want)
		}
	}
	r := &fakeRunner{replies: []reply{{match: "get namespace devzone-argocd", status: 1}}}
	if ArgoCDInstalled(r) {
		t.Fatal("a namespace that cannot be found counts as installed")
	}
}
