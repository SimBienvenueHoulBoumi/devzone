package agent

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestRightsIgnoreInheritedGitDir checks that the rights watcher still reads
// the project it was given when a hook exported another repository.
func TestRightsIgnoreInheritedGitDir(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "projet")
	decoy := filepath.Join(root, "decoy")
	state := t.TempDir()
	agentFile := filepath.Join(proj, ".devcontainer", "opencode", "agent.json")
	writeFileT(t, agentFile, `{"permission":{}}`)
	gitInit(t, proj)
	gitInit(t, decoy)
	t.Setenv("GIT_DIR", filepath.Join(decoy, ".git"))
	t.Setenv("GIT_WORK_TREE", decoy)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(decoy, ".git", "index"))

	ctx := context.Background()
	RightsSnapshot(ctx, ExecRunner{}, state, proj)
	head := testkit.Git(t, proj, "rev-parse", "HEAD") + "\n"
	if got := readFileString(filepath.Join(RightsDir(state, proj), "head")); got != head {
		t.Fatalf("snapshot head = %q, want %q", got, head)
	}
	writeFileT(t, agentFile, `{"permission":{}}`+"\npirate")
	testkit.Git(t, proj, "add", "-A")
	testkit.Git(t, proj, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "modif")
	journal := filepath.Join(state, "projet.log")
	RightsVerify(ctx, ExecRunner{}, state, proj, journal)
	if got := readFileString(agentFile); got != `{"permission":{}}` {
		t.Fatalf("rights file not restored: %q", got)
	}
	if got := readFileString(journal); !strings.Contains(got, "committed in") {
		t.Fatalf("no committed change in journal: %q", got)
	}
	if got := testkit.Git(t, decoy, "rev-list", "--count", "HEAD"); got != "2" {
		t.Errorf("decoy commits = %s, want 2", got)
	}
}
