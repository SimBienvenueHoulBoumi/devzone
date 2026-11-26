package ai

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// skillModel writes a versioned skill model in a temporary folder.
func writeSkillModel(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "SKILL.md")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestInstallSkillWritesBothFolders checks the install of a missing skill.
func TestInstallSkillWritesBothFolders(t *testing.T) {
	f := newFixture(t)
	model := writeSkillModel(t, skillMarker+"\n# devzone\n")
	if err := InstallSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	for _, dir := range skillDirs(f.o.home()) {
		data, err := os.ReadFile(filepath.Join(dir, "SKILL.md"))
		if err != nil || !strings.Contains(string(data), skillMarker) {
			t.Fatalf("skill in %s: %q, %v", dir, data, err)
		}
		if _, err := os.Stat(filepath.Join(dir, skillFingerprint)); err != nil {
			t.Fatalf("fingerprint in %s: %v", dir, err)
		}
	}
	if !strings.Contains(f.out.String(), "devzone skill installed in") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestInstallSkillUpdatesOnlyUnchanged checks the marker and fingerprint rules.
func TestInstallSkillUpdatesOnlyUnchanged(t *testing.T) {
	f := newFixture(t)
	model := writeSkillModel(t, skillMarker+"\n# devzone version 1\n")
	if err := InstallSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	newModel := writeSkillModel(t, skillMarker+"\n# devzone version 2\n")
	f.out.Reset()
	if err := InstallSkill(f.o, newModel); err != nil {
		t.Fatal(err)
	}
	if strings.Count(f.out.String(), "devzone skill updated in") != 2 {
		t.Fatalf("out = %q", f.out.String())
	}
	dir := skillDirs(f.o.home())[0]
	custom := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(custom, []byte("# my own skill\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.out.Reset()
	if err := InstallSkill(f.o, newModel); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.out.String(), "customised devzone skill") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestRemoveSkillKeepsCustomised checks the symmetrical removal rules.
func TestRemoveSkillKeepsCustomised(t *testing.T) {
	f := newFixture(t)
	model := writeSkillModel(t, skillMarker+"\n# devzone\n")
	if err := InstallSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	if err := RemoveSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	for _, dir := range skillDirs(f.o.home()) {
		if _, err := os.Stat(filepath.Join(dir, "SKILL.md")); !os.IsNotExist(err) {
			t.Fatalf("skill still in %s: %v", dir, err)
		}
	}
	if err := InstallSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	dir := skillDirs(f.o.home())[0]
	if err := os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte("# own\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RemoveSkill(f.o, model); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "SKILL.md")); err != nil {
		t.Fatalf("customised skill was removed: %v", err)
	}
}
