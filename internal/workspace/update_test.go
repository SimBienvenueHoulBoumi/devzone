package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// updateHarness holds the injected fakes of one update scenario.
type updateHarness struct {
	t       *testing.T
	env     UpdateEnv
	out     bytes.Buffer
	errOut  bytes.Buffer
	deploy  [][]string
	recon   int
	confirm bool
}

// newUpdateHarness builds an update whose cluster is ready and whose release
// and image exist; no test reaches git, a registry or a terminal.
func newUpdateHarness(t *testing.T, current string) *updateHarness {
	t.Helper()
	h := &updateHarness{t: t, confirm: true}
	runner := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "get namespace devzone-argocd", status: 1},
		{match: "get application.argoproj.io devzone-workspace", stdout: current},
		{match: "", stdout: ""},
	}}
	modules := filepath.Join(t.TempDir(), ".devzone.modules")
	h.env = UpdateEnv{
		Runner: runner, Modules: modules, Out: &h.out, ErrOut: &h.errOut,
		Ready:       func() (string, bool) { return "", true },
		Tags:        func(string) []string { return []string{"v0.47.0", "v0.48.0", "v0.9.0", "v0.48.0-rc1"} },
		ImageExists: func(string) bool { return true },
		Deploy: func(repository, tag, revision string) int {
			h.deploy = append(h.deploy, []string{repository, tag, revision})
			return 0
		},
		Reconcile: func() int { h.recon++; return 0 },
	}
	h.env.Confirm = func(question string) bool { return h.confirm }
	h.env.Terminal = func() bool { return true }
	return h
}

// TestLatestVersion checks that only stable tags count and that versions are
// ordered by number, not by text ("0.9" is before "0.48").
func TestLatestVersion(t *testing.T) {
	got := LatestVersion([]string{"v0.9.0", "v0.48.0", "v0.48.0-rc1", "0.99.0", "v1.2", "v1.10.0"})
	if got != "1.10.0" {
		t.Fatalf("latest = %q", got)
	}
	if got := LatestVersion([]string{"v0.1.0-rc1"}); got != "" {
		t.Fatalf("latest without a stable tag = %q", got)
	}
}

// TestUpdateOptions checks the option parsing and the version shape.
func TestUpdateOptions(t *testing.T) {
	version, yes, errOut, ok := parseUpdateOptions([]string{"--version", "1.2.3", "--yes"})
	if !ok || version != "1.2.3" || !yes || errOut != "" {
		t.Fatalf("version %q yes %v error %q ok %v", version, yes, errOut, ok)
	}
	if _, _, errOut, ok := parseUpdateOptions([]string{"--bogus"}); ok || !strings.Contains(errOut, "unknown option") {
		t.Fatalf("bogus option accepted: %q", errOut)
	}
	if _, _, errOut, ok := parseUpdateOptions([]string{"--version"}); ok || !strings.Contains(errOut, "give X.Y.Z") {
		t.Fatalf("missing version accepted: %q", errOut)
	}
	for _, bad := range []string{"", "1.2", "1.2.3.4", "v1.2.3", "1.2.x"} {
		if validRelease(bad) {
			t.Fatalf("invalid release %q accepted", bad)
		}
	}
}

// TestUpdateRelease checks the whole successful path at an explicit release.
func TestUpdateRelease(t *testing.T) {
	h := newUpdateHarness(t, "v0.47.0 0.47.0")
	if status := h.env.Run([]string{"--version", "0.48.0", "--yes"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if len(h.deploy) != 1 || strings.Join(h.deploy[0], " ") != imageRepo()+" 0.48.0 v0.48.0" {
		t.Fatalf("deploy = %v", h.deploy)
	}
	if !strings.Contains(h.out.String(), "✔ workspace on v0.48.0") {
		t.Fatalf("out = %q", h.out.String())
	}
	if h.recon != 0 {
		t.Fatalf("reconcile called without Argo CD")
	}
}

// TestUpdateLatestResolvesAndReconciles checks the automatic version and that
// services are reconciled when Argo CD holds the charts.
func TestUpdateLatestResolvesAndReconciles(t *testing.T) {
	h := newUpdateHarness(t, "v0.47.0 0.47.0")
	if err := os.WriteFile(h.env.Modules, []byte("argocd=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.env.Runner = &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "get namespace devzone-argocd", status: 0},
		{match: "get application.argoproj.io devzone-workspace", stdout: "v0.47.0 0.47.0"},
		{match: "", stdout: ""},
	}}
	if status := h.env.Run([]string{"--yes"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if len(h.deploy) != 1 || h.deploy[0][1] != "0.48.0" {
		t.Fatalf("deploy = %v", h.deploy)
	}
	if h.recon != 1 {
		t.Fatalf("reconcile called %d times", h.recon)
	}
}

// TestUpdateRefusals checks that nothing is deployed when the release is
// absent, already current, unpublished, unconfirmed or the cluster is down.
func TestUpdateRefusals(t *testing.T) {
	for _, tc := range []struct {
		name       string
		args       []string
		change     func(*updateHarness)
		want       string
		wantStatus int
	}{
		{name: "already current", args: []string{"--version", "0.47.0", "--yes"}, want: "already up to date", wantStatus: 0},
		{name: "bad version", args: []string{"--version", "1.2", "--yes"}, want: "expected X.Y.Z", wantStatus: 1},
		{name: "missing image", args: []string{"--version", "0.48.0", "--yes"},
			change: func(h *updateHarness) { h.env.ImageExists = func(string) bool { return false } },
			want:   "not found on ghcr.io", wantStatus: 1},
		{name: "no stable release", args: []string{"--yes"},
			change: func(h *updateHarness) { h.env.Tags = func(string) []string { return nil } },
			want:   "no stable release found", wantStatus: 1},
		{name: "no terminal", args: []string{"--version", "0.48.0"},
			change: func(h *updateHarness) { h.env.Terminal = func() bool { return false } },
			want:   "no terminal to confirm", wantStatus: 1},
		{name: "canceled", args: []string{"--version", "0.48.0"},
			change: func(h *updateHarness) { h.confirm = false }, want: "canceled", wantStatus: 1},
		{name: "cluster down", args: []string{"--version", "0.48.0", "--yes"},
			change: func(h *updateHarness) {
				h.env.Ready = func() (string, bool) { return "✖ cluster unreachable", false }
			}, want: "cluster unreachable", wantStatus: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newUpdateHarness(t, "v0.47.0 0.47.0")
			if tc.change != nil {
				tc.change(h)
			}
			status := h.env.Run(tc.args)
			if status != tc.wantStatus || !strings.Contains(h.errOut.String(), tc.want) && !strings.Contains(h.out.String(), tc.want) {
				t.Fatalf("status = %d, out = %q, errOut = %q, want %q", status, h.out.String(), h.errOut.String(), tc.want)
			}
			if len(h.deploy) != 0 {
				t.Fatalf("deploy called on a refusal: %v", h.deploy)
			}
		})
	}
}
