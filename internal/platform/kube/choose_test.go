package kube

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// fakeKube programs the neutral kubectl answers used by the choice tests.
func fakeKube(t *testing.T) *Kube {
	t.Helper()
	r := withRunner(t)
	t.Setenv("DEVZONE_INSTANCE", "devzone")
	hostFile(t)
	r.On("kubectl", nil, exec.Result{})
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{
		Stdout: []byte("rancher-desktop\ncluster-prod\nkind-devzone\n"),
	})
	return &Kube{Runner: r}
}

// TestCandidatesOrder checks local clusters, then the dedicated kind, then remotes.
func TestCandidatesOrder(t *testing.T) {
	k := fakeKube(t)
	names, err := k.Candidates(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := "rancher-desktop kind-devzone cluster-prod"
	if strings.Join(names, " ") != want {
		t.Fatalf("candidates = %q, want %q", strings.Join(names, " "), want)
	}
}

// TestChooseRemoteConfirmation checks the exact confirmations and refusals.
func TestChooseRemoteConfirmation(t *testing.T) {
	for _, tc := range []struct {
		name, confirm, remote, wantErr string
		code                           int
	}{
		{"outside a terminal", "", "", "remote cluster refused: cluster-prod (--confirm cluster-prod)", 2},
		{"exact flag", "cluster-prod", "", "", 0},
		{"wrong flag", "other", "", "remote cluster refused: cluster-prod (--confirm cluster-prod)", 2},
		{"test confirmation", "", "cluster-prod", "", 0},
		{"wrong test confirmation", "", "other", "DEVZONE_CLUSTER_REMOTE must be exactly cluster-prod", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			k := fakeKube(t)
			var errOut bytes.Buffer
			got, code := k.Choose(context.Background(), ChooseOptions{
				Wanted: "cluster-prod", Confirm: tc.confirm, Remote: tc.remote, Err: &errOut,
			})
			if code != tc.code || (code == 0 && got != "cluster-prod") {
				t.Fatalf("Choose = %q, %d; want code %d", got, code, tc.code)
			}
			if !strings.Contains(errOut.String(), tc.wantErr) {
				t.Fatalf("error = %q, want %q", errOut.String(), tc.wantErr)
			}
		})
	}
}

// TestChooseSavedAndDefault checks that a saved choice wins and that the local
// host context is the default when no choice was saved.
func TestChooseSavedAndDefault(t *testing.T) {
	k := fakeKube(t)
	got, code := k.Choose(context.Background(), ChooseOptions{Saved: "my-choice"})
	if code != 0 || got != "my-choice" {
		t.Fatalf("saved: %q, %d", got, code)
	}
}

// TestChooseFallbackKind checks the dedicated kind fallback when no host
// context is reachable.
func TestChooseFallbackKind(t *testing.T) {
	k := fakeKube(t)
	r, ok := k.Runner.(*fake.Runner)
	if !ok {
		t.Fatal("runner is not a fake")
	}
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{})
	got, code := k.Choose(context.Background(), ChooseOptions{})
	if code != 0 || got != "kind-devzone" {
		t.Fatalf("fallback: %q, %d", got, code)
	}
}

// TestMenuSelection checks Enter, an explicit number and an out-of-list answer.
func TestMenuSelection(t *testing.T) {
	for _, tc := range []struct {
		answer string
		want   string
		code   int
	}{
		{"\n", "rancher-desktop", 0},
		{"3\n", "kind-devzone", 0},
		{"9\n", "", 2},
		{"abc\n", "", 2},
	} {
		t.Run(tc.answer, func(t *testing.T) {
			k := fakeKube(t)
			var out, errOut bytes.Buffer
			got, code := k.Menu(context.Background(), []string{"rancher-desktop", "cluster-prod", "kind-devzone"},
				strings.NewReader(tc.answer), &out, &errOut)
			if code != tc.code || got != tc.want {
				t.Fatalf("Menu = %q, %d; want %q, %d", got, code, tc.want, tc.code)
			}
			if !strings.Contains(errOut.String(), "Number [1]: ") {
				t.Fatalf("menu = %q", errOut.String())
			}
		})
	}
}

// TestSavedAndSaveContext checks the state lines of the chosen cluster.
func TestSavedAndSaveContext(t *testing.T) {
	path := filepath.Join(testkit.TempHome(t), ".devzone.modules")
	if err := os.WriteFile(path, []byte("postgres=on\ncluster=old\ncluster=saved\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := SavedContext(path); got != "saved" {
		t.Fatalf("SavedContext = %q, want saved", got)
	}
	if err := SaveContext(path, "new"); err != nil {
		t.Fatal(err)
	}
	if got := SavedContext(path); got != "new" {
		t.Fatalf("SavedContext = %q, want new", got)
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "postgres=on\n") {
		t.Fatalf("state = %q, err %v", data, err)
	}
}
