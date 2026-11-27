package argocd

import (
	"errors"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// errOffline simulates a network failure of an injected runner command.
var errOffline = errors.New("network unreachable")

// renderCalls renders the recorded runner calls as one line each, for exact
// assertions on the commands of a revision resolution.
func renderCalls(r *fake.Runner) []string {
	out := []string{}
	for _, call := range r.Calls() {
		out = append(out, strings.TrimSpace(call.Name+" "+strings.Join(call.Args, " ")))
	}
	return out
}

// revisionFixture gives a test an empty root, a clean environment and a fake
// runner, so that no test can reach the network or the real repository.
func revisionFixture(t *testing.T) (*fake.Runner, RevisionInputs) {
	t.Helper()
	t.Setenv("DEVZONE_ARGOCD_REVISION", "")
	t.Setenv("DEVZONE_REPO_URL", "")
	root := t.TempDir()
	r := fake.New()
	return r, RevisionInputs{
		Runner: r,
		Root:   root,
		Repo:   "https://github.com/acme/devzone.git",
		Chart:  "devzone-mysql",
	}
}

// TestResolveRevisionExplicit checks that an explicit override wins over the
// package version and needs no runner call.
func TestResolveRevisionExplicit(t *testing.T) {
	r, in := revisionFixture(t)
	t.Setenv("DEVZONE_ARGOCD_REVISION", "feature-branch")
	writeTestFile(t, in.Root+"/package.json", `{"version": "1.2.3"}`+"\n")
	got, err := ResolveRevision(t.Context(), in)
	if err != nil || got != "feature-branch" {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("unexpected runner calls: %v", r.Calls())
	}
}

// TestResolveRevisionKeptSetting checks the revision kept in .argocd.conf.
func TestResolveRevisionKeptSetting(t *testing.T) {
	_, in := revisionFixture(t)
	writeTestFile(t, in.Root+"/.argocd.conf", "[argocd]\nrevision = v2.0.0\n")
	writeTestFile(t, in.Root+"/package.json", `{"version": "1.2.3"}`+"\n")
	got, err := ResolveRevision(t.Context(), in)
	if err != nil || got != "v2.0.0" {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
}

// TestResolveRevisionPackage checks the released version of the package.
func TestResolveRevisionPackage(t *testing.T) {
	_, in := revisionFixture(t)
	writeTestFile(t, in.Root+"/package.json", "{\n  \"version\": \"3.4.5\"\n}\n")
	got, err := ResolveRevision(t.Context(), in)
	if err != nil || got != "v3.4.5" {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
}

// TestResolveRevisionLatestTag checks that a development clone picks the
// newest stable tag that carries the chart, skipping previews and older tags.
func TestResolveRevisionLatestTag(t *testing.T) {
	r, in := revisionFixture(t)
	writeTestFile(t, in.Root+"/package.json", `{"version": "0.0.0"}`+"\n")
	tags := "sha1\trefs/tags/v9.9.9\n" +
		"sha2\trefs/tags/v2.0.0-next.1\n" +
		"sha3\trefs/tags/v1.10.0\n" +
		"sha4\trefs/tags/v1.9.0\n" +
		"sha5\trefs/tags/not-a-version\n"
	r.On("git", []string{"ls-remote", "--tags", "--refs", in.Repo}, fexec.Result{Stdout: []byte(tags)})
	for _, tag := range []string{"v9.9.9", "v1.10.0", "v1.9.0"} {
		path := "repos/acme/devzone/contents/charts/devzone-mysql?ref=" + tag
		code := 1
		if tag == "v1.9.0" {
			code = 0
		}
		r.On("gh", []string{"api", path, "--jq", ".type"}, fexec.Result{Stdout: []byte("dir\n"), Code: code})
	}
	got, err := ResolveRevision(t.Context(), in)
	if err != nil || got != "v1.9.0" {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
	want := []string{
		"git ls-remote --tags --refs " + in.Repo,
		"gh api repos/acme/devzone/contents/charts/devzone-mysql?ref=v9.9.9 --jq .type",
		"gh api repos/acme/devzone/contents/charts/devzone-mysql?ref=v1.10.0 --jq .type",
		"gh api repos/acme/devzone/contents/charts/devzone-mysql?ref=v1.9.0 --jq .type",
	}
	if got := renderCalls(r); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("calls = %v, want %v", got, want)
	}
}

// TestResolveRevisionNetworkFailure checks that an unreachable repository is
// reported clearly, with no chart call and no installation attempted.
func TestResolveRevisionNetworkFailure(t *testing.T) {
	r, in := revisionFixture(t)
	writeTestFile(t, in.Root+"/package.json", `{"version": "0.0.0"}`+"\n")
	r.OnError("git", []string{"ls-remote", "--tags", "--refs", in.Repo}, fexec.Result{}, errOffline)
	got, err := ResolveRevision(t.Context(), in)
	if got != "" || err == nil {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
	if !strings.Contains(err.Error(), "cannot list the tags") || !strings.Contains(err.Error(), "DEVZONE_ARGOCD_REVISION") {
		t.Fatalf("unclear error: %v", err)
	}
	if len(r.Calls()) != 1 {
		t.Fatalf("unexpected runner calls: %v", renderCalls(r))
	}
}

// TestResolveRevisionNoChartTag checks the error when no published tag holds
// the chart, so that no caller can quietly install with helm.
func TestResolveRevisionNoChartTag(t *testing.T) {
	r, in := revisionFixture(t)
	writeTestFile(t, in.Root+"/package.json", `{"version": "0.0.0"}`+"\n")
	r.On("git", []string{"ls-remote", "--tags", "--refs", in.Repo}, fexec.Result{Stdout: []byte("sha\trefs/tags/v1.0.0\n")})
	r.On("gh", []string{"api", "repos/acme/devzone/contents/charts/devzone-mysql?ref=v1.0.0", "--jq", ".type"}, fexec.Result{Code: 1})
	got, err := ResolveRevision(t.Context(), in)
	if got != "" || err == nil || !strings.Contains(err.Error(), "no published tag") {
		t.Fatalf("revision = %q, err = %v", got, err)
	}
}
