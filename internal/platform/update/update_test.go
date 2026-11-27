package update

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// TestUpToDateTouchesNothing checks that the same version with every file present
// changes nothing, creates no backup, starts nothing, and suggests npx.
func TestUpToDateTouchesNothing(t *testing.T) {
	v1 := newPackage(t, "0.0.1", "ancien")
	f := newFixture(t, v1, v1)
	before := f.read(f.folder, ".devzone.version")
	if code := Run(f.options(false, false, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "already up to date") || !strings.Contains(f.out.String(), "npx devzone@latest update") {
		t.Errorf("output = %q", f.out.String())
	}
	if f.read(f.folder, ".devzone.version") != before || exists(filepath.Join(f.folder, ".devzone.backup")) || len(f.calls) != 0 {
		t.Error("an up-to-date folder was changed")
	}
}

// TestSameVersionMissingFileRestored checks that a package file deleted from a
// folder at the same version is copied back.
func TestSameVersionMissingFileRestored(t *testing.T) {
	v1 := newPackage(t, "0.0.1", "ancien")
	f := newFixture(t, v1, v1)
	if err := os.Remove(filepath.Join(f.folder, "Makefile")); err != nil {
		t.Fatal(err)
	}
	if code := Run(f.options(false, false, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if got := f.read(f.folder, "Makefile"); got != "# makefile ancien\n" {
		t.Errorf("Makefile = %q", got)
	}
	if f.version() != "0.0.1" || len(f.calls) != 0 {
		t.Errorf("version = %s, calls = %v", f.version(), f.calls)
	}
}

// TestUpgradeReplacesRemovesAndBacksUp checks v1 → v2: the package files are
// replaced, the old package file is removed, the replaced files are backed up, and
// the user's files are intact.
func TestUpgradeReplacesRemovesAndBacksUp(t *testing.T) {
	v1 := newPackage(t, "0.0.1", "ancien")
	v2 := newPackage(t, "0.0.2", "nouveau")
	write(t, v1, "manage/scripts/ancien.sh", "echo ancien\n")
	write(t, v2, ".devcontainer/nouveau.txt", "nouveau\n")
	f := newFixture(t, v1, v2)
	write(t, f.folder, "workspace/projet/file", "projet\n")
	write(t, f.folder, ".devzone.modules", "ai=on\n")
	write(t, f.folder, ".password", "secret\n")
	write(t, f.folder, ".app", "app\n")
	write(t, f.folder, ".devzone.log", "journal\n")
	if code := Run(f.options(false, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if f.read(f.folder, "Makefile") != "# makefile nouveau\n" || f.read(f.folder, ".devcontainer/nouveau.txt") != "nouveau\n" {
		t.Error("package files not replaced")
	}
	if exists(filepath.Join(f.folder, "manage/scripts/ancien.sh")) {
		t.Error("old package file kept")
	}
	if f.version() != "0.0.2" {
		t.Errorf("version = %s", f.version())
	}
	if f.read(f.backupDir(), "Makefile") != "# makefile ancien\n" || f.read(f.backupDir(), "manage/scripts/ancien.sh") != "echo ancien\n" {
		t.Error("replaced or removed files not backed up")
	}
	for rel, want := range map[string]string{"workspace/projet/file": "projet\n", ".devzone.modules": "ai=on\n",
		".password": "secret\n", ".app": "app\n", ".devzone.log": "journal\n"} {
		if got := f.read(f.folder, rel); got != want {
			t.Errorf("%s = %q, want %q", rel, got, want)
		}
	}
	if !strings.Contains(f.out.String(), "Sauvegarde : "+f.backupDir()) {
		t.Errorf("no backup notice in %q", f.out.String())
	}
	if len(f.calls) != 0 {
		t.Errorf("a rebuild or a watcher ran: %v", f.calls)
	}
}

// TestModifiedRefusedWithoutYesAndTerminal checks that a file the user changed is
// not replaced without --yes or an answer, and that nothing is touched.
func TestModifiedRefusedWithoutYesAndTerminal(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, "Makefile", "modifie a la main\n")
	if code := Run(f.options(false, false, false)); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(f.out.String(), "Makefile") || !strings.Contains(f.errOut.String(), "--yes") {
		t.Errorf("out = %q, err = %q", f.out.String(), f.errOut.String())
	}
	if f.read(f.folder, "Makefile") != "modifie a la main\n" || f.version() != "0.0.1" || exists(filepath.Join(f.folder, ".devzone.backup")) {
		t.Error("a refused update changed the folder")
	}
}

// TestModifiedReplacedWithYes checks that a changed file is backed up, then
// replaced, when --yes is given.
func TestModifiedReplacedWithYes(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, "Makefile", "modifie a la main\n")
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if f.read(f.folder, "Makefile") != "# makefile nouveau\n" {
		t.Error("Makefile not replaced")
	}
	if f.read(f.backupDir(), "Makefile") != "modifie a la main\n" {
		t.Error("the user's version is not in the backup")
	}
}

// TestModifiedAnsweredYes checks that a terminal answer of yes replaces the changed
// file, and that an answer of no leaves everything as it was.
func TestModifiedAnsweredYes(t *testing.T) {
	for _, tc := range []struct {
		answer string
		code   int
	}{{"y\n", 0}, {"n\n", 1}} {
		f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
		write(t, f.folder, "Makefile", "modifie a la main\n")
		f.answer = tc.answer
		if code := Run(f.options(false, true, true)); code != tc.code {
			t.Errorf("answer %q: code = %d, want %d", tc.answer, code, tc.code)
		}
		wantMakefile := "modifie a la main\n"
		if tc.code == 0 {
			wantMakefile = "# makefile nouveau\n"
		}
		if got := f.read(f.folder, "Makefile"); got != wantMakefile {
			t.Errorf("answer %q: Makefile = %q", tc.answer, got)
		}
	}
}

// TestLocalArgoConfigNeverTouched checks that the GitOps configuration of the
// folder is never replaced nor backed up: it is not a package file.
func TestLocalArgoConfigNeverTouched(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	conf := "[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n"
	write(t, f.folder, ".argocd.conf", conf)
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.read(f.folder, ".argocd.conf") != conf || exists(filepath.Join(f.backupDir(), ".argocd.conf")) {
		t.Error(".argocd.conf was changed or backed up")
	}
}

// TestUserScriptsKeptWithManifest checks that a scripts/ folder the user made is
// kept when the folder has a manifest.
func TestUserScriptsKeptWithManifest(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, "scripts/mon-outil.sh", "#!/usr/bin/env bash\necho moi\n")
	if code := Run(f.options(false, true, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.read(f.folder, "scripts/mon-outil.sh") != "#!/usr/bin/env bash\necho moi\n" || exists(filepath.Join(f.backupDir(), "scripts/mon-outil.sh")) {
		t.Error("the user's script was touched or backed up")
	}
	if f.version() != "0.0.2" {
		t.Errorf("version = %s", f.version())
	}
}

// TestUserScriptsKeptWithoutManifest checks the same without any manifest: every
// file of the package differs, and the user's script is still kept.
func TestUserScriptsKeptWithoutManifest(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	if err := os.Remove(filepath.Join(f.folder, manifest.FileName)); err != nil {
		t.Fatal(err)
	}
	write(t, f.folder, "scripts/mon-outil.sh", "mon outil\n")
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if f.read(f.folder, "scripts/mon-outil.sh") != "mon outil\n" || f.version() != "0.0.2" {
		t.Error("the user's script was removed or the manifest not rewritten")
	}
}
