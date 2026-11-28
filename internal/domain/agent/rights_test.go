package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

func writeFileT(t *testing.T, p, content string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func gitInit(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	testkit.Git(t, dir, "init", "-q")
	testkit.Git(t, dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "depart", "--allow-empty")
	testkit.Git(t, dir, "add", "-A")
	testkit.Git(t, dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "add", "--allow-empty")
}

func TestRightsFilesList(t *testing.T) {
	want := []string{".devcontainer/opencode/agent.json", ".devcontainer/opencode.jsonc", ".repowarden.conf", "internal/domain/agent/rights.go"}
	if len(RightsFiles) != 4 {
		t.Fatal("len", RightsFiles)
	}
	for i, w := range want {
		if RightsFiles[i] != w {
			t.Fatal("list", RightsFiles)
		}
	}
}

func TestRightsSnapshotRestore(t *testing.T) {
	dir := t.TempDir()
	state := t.TempDir()
	proj := filepath.Join(dir, "projet")
	writeFileT(t, filepath.Join(proj, ".devcontainer", "opencode", "agent.json"), `{"permission":{}}`)
	writeFileT(t, filepath.Join(proj, ".devcontainer", "opencode.jsonc"), "defaut")
	writeFileT(t, filepath.Join(proj, "internal", "domain", "agent", "rights.go"), "# rights\n")
	// .repowarden.conf absent
	ctx := context.Background()
	RightsSnapshot(ctx, ExecRunner{}, state, proj)
	// agent modifies + creates + removes
	writeFileT(t, filepath.Join(proj, ".devcontainer", "opencode", "agent.json"), `{"permission":{}}`+"\npirate")
	writeFileT(t, filepath.Join(proj, ".repowarden.conf"), "{}")
	os.Remove(filepath.Join(proj, ".devcontainer", "opencode.jsonc"))
	journal := filepath.Join(state, "projet.log")
	RightsVerify(ctx, ExecRunner{}, state, proj, journal)
	if got := readFileString(filepath.Join(proj, ".devcontainer", "opencode", "agent.json")); got != `{"permission":{}}` {
		t.Fatal("agent.json not restored", got)
	}
	if got := readFileString(filepath.Join(proj, ".devcontainer", "opencode.jsonc")); got != "defaut" {
		t.Fatal("opencode.jsonc not restored", got)
	}
	if fileExists(filepath.Join(proj, ".repowarden.conf")) {
		t.Fatal(".repowarden.conf created not removed")
	}
	j := readFileString(journal)
	if !strings.Contains(j, "=== ⚠ rights changed: .devcontainer/opencode/agent.json : change reverted") {
		t.Fatal("no alert agent.json", j)
	}
	if !strings.Contains(j, ".repowarden.conf : change reverted") {
		t.Fatal("no alert conf", j)
	}
	if !fileExists(filepath.Join(state, "droits-projet.alerte")) {
		t.Fatal("no .alerte")
	}
	// absent list
	if !strings.Contains(readFileString(filepath.Join(state, "droits-projet", "absents")), ".repowarden.conf") {
		t.Fatal("absents not noted")
	}
	// rights.go protected (not modified, still listed)
	if got := readFileString(filepath.Join(proj, "internal", "domain", "agent", "rights.go")); got != "# rights\n" {
		t.Fatal("rights.go touched")
	}
}

func TestRightsVerifyCommittedChange(t *testing.T) {
	dir := t.TempDir()
	state := t.TempDir()
	proj := filepath.Join(dir, "projet")
	writeFileT(t, filepath.Join(proj, ".devcontainer", "opencode", "agent.json"), `{"permission":{}}`)
	os.MkdirAll(filepath.Join(proj, ".devcontainer", "opencode"), 0o755)
	gitInit(t, proj)
	ctx := context.Background()
	RightsSnapshot(ctx, ExecRunner{}, state, proj)
	// agent modifies + commits
	writeFileT(t, filepath.Join(proj, ".devcontainer", "opencode", "agent.json"), `{"permission":{}}`+"\npirate")
	git := func(args ...string) string { return testkit.Git(t, proj, args...) }
	git("add", "-A")
	git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "modif")
	before, err := strconv.Atoi(strings.TrimSpace(git("rev-list", "--count", "HEAD")))
	if err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(state, "projet.log")
	RightsVerify(ctx, ExecRunner{}, state, proj, journal)
	if got := readFileString(filepath.Join(proj, ".devcontainer", "opencode", "agent.json")); got != `{"permission":{}}` {
		t.Fatal("committed change not restored in tree", got)
	}
	after, err := strconv.Atoi(strings.TrimSpace(git("rev-list", "--count", "HEAD")))
	if err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("history rewritten: before=%d after=%d", before, after)
	}
	j := readFileString(journal)
	if !strings.Contains(j, "committed in") || !strings.Contains(j, "remove this commit before any push") {
		t.Fatal("no committed message", j)
	}
	if !fileExists(filepath.Join(state, "droits-projet.alerte")) {
		t.Fatal("no alerte")
	}
}

func TestRightsAlerts(t *testing.T) {
	state := t.TempDir()
	writeFileT(t, filepath.Join(state, "droits-dz-361.alerte"), "")
	if got := RightsAlerts(state); !strings.Contains(got, "⚠ rights changed (dz-361): see the journal") {
		t.Fatal("alerts", got)
	}
}

func TestRightsSnapshotClearsAlert(t *testing.T) {
	dir := t.TempDir()
	state := t.TempDir()
	proj := filepath.Join(dir, "p")
	writeFileT(t, filepath.Join(proj, ".repowarden.conf"), "x")
	writeFileT(t, filepath.Join(state, "droits-p.alerte"), "x")
	RightsSnapshot(context.Background(), ExecRunner{}, state, proj)
	if fileExists(filepath.Join(state, "droits-p.alerte")) {
		t.Fatal("alert not cleared")
	}
}
