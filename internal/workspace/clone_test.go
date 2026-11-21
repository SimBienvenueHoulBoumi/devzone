package workspace

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cloneIdentity is the git identity of the workstation in the tests
func cloneIdentity(key string) string {
	if key == "user.name" {
		return "Dev Test"
	}
	if key == "user.email" {
		return "dev@example.test"
	}
	return ""
}

// noIdentity is the git identity of a workstation without user.name or user.email
func noIdentity(string) string { return "" }

// cloneFake answers the calls of a clone: no devzone context declared, and
// kubectl exec answered with status and stdout.
func cloneFake(status int, stdout string) *fakeRunner {
	return &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "lab\n"},
		{match: "exec -i", status: status, stdout: stdout},
	}}
}

func TestCloneWithoutURL(t *testing.T) {
	f := cloneFake(0, "")
	var errOut bytes.Buffer
	if got := Clone(f, cloneIdentity, "", "", &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("status = %d, want 1", got)
	}
	if errOut.String() != cloneUsage+"\n" || len(f.calls) != 0 {
		t.Fatalf("stderr %q, calls %v: want the usage and no kubectl call", errOut.String(), f.calls)
	}
}

func TestCloneNameFromURL(t *testing.T) {
	cases := map[string]string{
		"https://github.com/acme/mine.git":  "mine",
		"https://github.com/acme/mine":      "mine",
		"https://github.com/acme/mine/":     "mine",
		"https://github.com/acme/mine.git/": "mine",
		"git@github.com:acme/mine.git":      "mine",
		"git@github.com:mine.git":           "mine",
		"ssh://host:2222/acme/mine.git":     "mine",
	}
	for url, want := range cases {
		if got := cloneName(url); got != want {
			t.Errorf("cloneName(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestCloneInvalidName(t *testing.T) {
	const url = "https://github.com/acme/mine.git"
	cases := []struct {
		url, name, want string
	}{
		{url, "..", "✖ invalid folder name: .. (letters, digits, . _ - only)\n"},
		{url, ".", "✖ invalid folder name: . (letters, digits, . _ - only)\n"},
		{url, "-x", "✖ invalid folder name: -x (letters, digits, . _ - only)\n"},
		{url, "a/b", "✖ invalid folder name: a/b (letters, digits, . _ - only)\n"},
		{url, "a b", "✖ invalid folder name: a b (letters, digits, . _ - only)\n"},
		{url, "a+b", "✖ invalid folder name: a+b (letters, digits, . _ - only)\n"},
		// a url without name gives an empty name: the message says "empty"
		{"/", "", "✖ invalid folder name: empty (letters, digits, . _ - only)\n"},
	}
	for _, c := range cases {
		f := cloneFake(0, "")
		var errOut bytes.Buffer
		if got := Clone(f, cloneIdentity, c.url, c.name, &bytes.Buffer{}, &errOut); got != 1 {
			t.Errorf("name %q: status = %d, want 1", c.name, got)
		}
		if errOut.String() != c.want || len(f.calls) != 0 {
			t.Errorf("name %q: stderr %q, calls %v: want %q and no kubectl call", c.name, errOut.String(), f.calls, c.want)
		}
	}
}

func TestCloneRunsPodScriptWithNameAndIdentity(t *testing.T) {
	f := cloneFake(0, "cloned\n")
	var out bytes.Buffer
	if got := Clone(f, cloneIdentity, "https://github.com/acme/mine.git", "", &out, &bytes.Buffer{}); got != 0 {
		t.Fatalf("status = %d, want 0", got)
	}
	want := "exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash -s -- " +
		"/workspaces/projets/mine https://github.com/acme/mine.git Dev Test dev@example.test"
	if got := lastCall(t, f); got != want {
		t.Fatalf("kubectl call = %q, want %q", got, want)
	}
	if f.stdins[len(f.stdins)-1] != cloneScript {
		t.Fatalf("pod script = %q, want cloneScript", f.stdins[len(f.stdins)-1])
	}
	if out.String() != "cloned\n" {
		t.Fatalf("stdout = %q: want the output of kubectl", out.String())
	}
}

func TestCloneGivenNameWins(t *testing.T) {
	f := cloneFake(0, "")
	Clone(f, cloneIdentity, "https://github.com/acme/mine.git", "autre", &bytes.Buffer{}, &bytes.Buffer{})
	if got := lastCall(t, f); !strings.Contains(got, " -- bash -s -- /workspaces/projets/autre https://github.com/acme/mine.git ") {
		t.Fatalf("kubectl call = %q: want the folder autre", got)
	}
}

func TestCloneWithoutIdentityPassesEmptyValues(t *testing.T) {
	f := cloneFake(0, "")
	Clone(f, noIdentity, "https://github.com/acme/mine.git", "", &bytes.Buffer{}, &bytes.Buffer{})
	if got := lastCall(t, f); !strings.HasSuffix(got, "https://github.com/acme/mine.git  ") {
		t.Fatalf("kubectl call = %q: want two empty identity arguments", got)
	}
}

func TestClonePodStatusIsReturned(t *testing.T) {
	f := cloneFake(3, "")
	if got := Clone(f, cloneIdentity, "https://github.com/acme/mine.git", "", &bytes.Buffer{}, &bytes.Buffer{}); got != 3 {
		t.Fatalf("status = %d, want 3 (the status of the pod script)", got)
	}
}

func TestCloneKubectlCannotStart(t *testing.T) {
	f := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "lab\n"},
		{match: "exec -i", err: errors.New("no such file")},
	}}
	var errOut bytes.Buffer
	if got := Clone(f, cloneIdentity, "https://github.com/acme/mine.git", "", &bytes.Buffer{}, &errOut); got != notStarted {
		t.Fatalf("status = %d, want %d", got, notStarted)
	}
	if want := "devzone: cannot start kubectl: no such file\n"; errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", errOut.String(), want)
	}
}

func TestIdentityReadsGitConfig(t *testing.T) {
	requireGit(t)
	config := filepath.Join(t.TempDir(), "gitconfig")
	if err := os.WriteFile(config, []byte("[user]\n\tname = Dev Test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Chdir(t.TempDir())
	if got := Identity("user.name"); got != "Dev Test" {
		t.Fatalf("Identity(user.name) = %q, want %q", got, "Dev Test")
	}
	if got := Identity("user.email"); got != "" {
		t.Fatalf("Identity(user.email) = %q, want empty", got)
	}
}
