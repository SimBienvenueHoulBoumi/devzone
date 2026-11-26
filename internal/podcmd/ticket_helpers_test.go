package podcmd

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// ticketFixture holds a bare origin and the roots of the ticket worktrees of one test.
type ticketFixture struct {
	root, origin, projects, tools string
}

// newTicketFixture creates a bare origin with a commit on develop, a fake repowarden and an isolated environment.
func newTicketFixture(t *testing.T) ticketFixture {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake repowarden is a shell script")
	}
	testkit.RequireGit(t)

	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(root, "gitconfig"))
	projects := filepath.Join(root, "projets")
	tools := filepath.Join(root, "tools")
	t.Setenv("DEVZONE_TICKET_PROJECTS", projects)
	t.Setenv("DEVZONE_TICKET_TOOLS", tools)
	t.Setenv("DEVZONE_WORKSPACE", "")

	origin := filepath.Join(root, "origin")
	seed := filepath.Join(root, "seed")
	testkit.Git(t, root, "config", "--global", "user.name", "Test")
	testkit.Git(t, root, "config", "--global", "user.email", "test@example.org")
	testkit.Git(t, root, "config", "--global", "init.defaultBranch", "develop")
	testkit.Git(t, root, "init", "-q", "--bare", origin)
	testkit.Git(t, root, "clone", "-q", origin, seed)
	testkit.Git(t, seed, "commit", "-q", "--allow-empty", "-m", "init")
	testkit.Git(t, seed, "push", "-q", "origin", "develop")

	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/usr/bin/env bash\n[ \"${FAKE_RW_FAIL:-}\" = 1 ] && exit 1\n[ \"$1\" = ticket ] && git checkout -q -b \"feat/$2-test\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(bin, "repowarden"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))

	return ticketFixture{root: root, origin: origin, projects: projects, tools: tools}
}

// clone clones the fixture origin into dest.
func (f ticketFixture) clone(t *testing.T, dest string) {
	t.Helper()
	testkit.Git(t, f.root, "clone", "-q", f.origin, dest)
}

// runTicketArgs runs runTicket with args and returns its standard output, error output and status.
func runTicketArgs(args ...string) (string, string, int) {
	var out, errOut strings.Builder
	code := runTicket(&cli.Context{Args: args, Out: &out, Err: &errOut})
	return out.String(), errOut.String(), code
}

// gitOut runs git -C dir with args through the shared helper and returns its trimmed output.
func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return testkit.Git(t, dir, args...)
}
