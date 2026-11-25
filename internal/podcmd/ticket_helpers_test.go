package podcmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"testing"
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
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}

	root := t.TempDir()
	for _, k := range []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR"} {
		t.Setenv(k, "")
		if err := os.Unsetenv(k); err != nil {
			t.Fatal(err)
		}
	}
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

	git := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		if dir == "" {
			cmd.Dir = root
		} else {
			cmd.Dir = dir
		}
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v in %s: %v\n%s", args, cmd.Dir, err, output)
		}
	}

	origin := filepath.Join(root, "origin")
	seed := filepath.Join(root, "seed")
	git("", "config", "--global", "user.name", "Test")
	git("", "config", "--global", "user.email", "test@example.org")
	git("", "config", "--global", "init.defaultBranch", "develop")
	git("", "init", "-q", "--bare", origin)
	git("", "clone", "-q", origin, seed)
	git(seed, "commit", "-q", "--allow-empty", "-m", "init")
	git(seed, "push", "-q", "origin", "develop")

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
	cmd := exec.Command("git", "clone", "-q", f.origin, dest)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git clone %s: %v\n%s", dest, err, output)
	}
}

// runTicketArgs runs runTicket with args and returns its standard output, error output and status.
func runTicketArgs(args ...string) (string, string, int) {
	var out, errOut strings.Builder
	code := runTicket(&cli.Context{Args: args, Out: &out, Err: &errOut})
	return out.String(), errOut.String(), code
}

// gitOut runs git -C dir with args and returns its trimmed standard output.
func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("git -C %s %v: %v", dir, args, err)
	}
	return strings.TrimSpace(string(output))
}
