package update

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// oldScriptsTree writes the files of an old scripts/ folder: the two marker files
// and one file of the user.
func oldScriptsTree(t *testing.T, folder string) {
	t.Helper()
	write(t, folder, "scripts/uninstall.sh", "vieux desinstaller\n")
	write(t, folder, "scripts/launch.sh", "vieux lancer\n")
	write(t, folder, "scripts/mon-outil.sh", "mon outil\n")
}

// TestOldScriptsRemovesOnlyDevzoneFiles checks that in an old scripts/ folder only
// the files the package delivered are removed; launch.sh, which the package no
// longer ships, and the user's file stay.
func TestOldScriptsRemovesOnlyDevzoneFiles(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	oldScriptsTree(t, f.folder)
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if exists(filepath.Join(f.folder, "scripts/uninstall.sh")) {
		t.Error("the old uninstall.sh was kept")
	}
	if f.read(f.folder, "scripts/launch.sh") != "vieux lancer\n" || f.read(f.folder, "scripts/mon-outil.sh") != "mon outil\n" {
		t.Error("a file of the user was removed")
	}
	if f.read(f.backupDir(), "scripts/uninstall.sh") != "vieux desinstaller\n" {
		t.Error("the removed file is not backed up")
	}
	if exists(filepath.Join(f.backupDir(), "scripts/launch.sh")) || exists(filepath.Join(f.backupDir(), "scripts/mon-outil.sh")) {
		t.Error("a kept file was backed up")
	}
}

// TestOldCoreTreeRemovedWhenEmpty checks that a recognized old core/ has its known
// files backed up and removed, and the folders that became empty with them.
func TestOldCoreTreeRemovedWhenEmpty(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, "core/devzone", "vieux devzone\n")
	write(t, f.folder, "core/scripts/uninstall.sh", "vieux desinstaller\n")
	write(t, f.folder, "core/test/ancien.bats", "vieux test\n")
	write(t, f.folder, "core/docs/ancien.md", "vieille doc\n")
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if exists(filepath.Join(f.folder, "core")) {
		t.Error("core/ was kept")
	}
	for rel, want := range map[string]string{"core/devzone": "vieux devzone\n", "core/scripts/uninstall.sh": "vieux desinstaller\n",
		"core/test/ancien.bats": "vieux test\n", "core/docs/ancien.md": "vieille doc\n"} {
		if got := f.read(f.backupDir(), rel); got != want {
			t.Errorf("backup %s = %q, want %q", rel, got, want)
		}
	}
}

// TestOldCoreWithoutManifestKeepsUnknownFile checks that without a manifest the
// known files of old core/ are backed up and removed, while a file the package
// never delivered is kept, and so is the core/ folder holding it.
func TestOldCoreWithoutManifestKeepsUnknownFile(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	if err := os.Remove(filepath.Join(f.folder, manifest.FileName)); err != nil {
		t.Fatal(err)
	}
	write(t, f.folder, "core/scripts/uninstall.sh", "vieux desinstaller\n")
	write(t, f.folder, "core/autre/my-file", "file of mine\n")
	write(t, f.folder, "workspace/projet/file", "projet\n")
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "inconnue") {
		t.Errorf("out = %q, want the unknown version", f.out.String())
	}
	if exists(filepath.Join(f.folder, "core/scripts")) || f.read(f.folder, "core/autre/my-file") != "file of mine\n" {
		t.Error("core/ content not handled as expected")
	}
	if f.read(f.backupDir(), "core/scripts/uninstall.sh") != "vieux desinstaller\n" || exists(filepath.Join(f.backupDir(), "core/autre/my-file")) {
		t.Error("backup holds the wrong files")
	}
	if f.read(f.folder, "workspace/projet/file") != "projet\n" || f.version() != "0.0.2" {
		t.Error("workspace touched or manifest not rewritten")
	}
}

// TestOldTreesWithoutTerminalRefused checks that an old layout with files to
// remove is refused without a terminal and without --yes, and nothing is touched.
func TestOldTreesWithoutTerminalRefused(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	oldScriptsTree(t, f.folder)
	write(t, f.folder, "core/devzone", "vieux devzone\n")
	write(t, f.folder, "core/scripts/uninstall.sh", "vieux core\n")
	if code := Run(f.options(false, true, false)); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(f.out.String(), "scripts/uninstall.sh") || !strings.Contains(f.errOut.String(), "--yes") {
		t.Errorf("out = %q, err = %q", f.out.String(), f.errOut.String())
	}
	if f.read(f.folder, "scripts/uninstall.sh") != "vieux desinstaller\n" || f.read(f.folder, "core/devzone") != "vieux devzone\n" || f.version() != "0.0.1" {
		t.Error("a refused update changed the folder")
	}
	if exists(filepath.Join(f.folder, ".devzone.backup")) {
		t.Error("a refused update made a backup")
	}
}

// TestOldFolderWithoutManifestNeedsYes checks that without a manifest every
// differing package file is a modification, so --yes is required.
func TestOldFolderWithoutManifestNeedsYes(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	if err := os.Remove(filepath.Join(f.folder, manifest.FileName)); err != nil {
		t.Fatal(err)
	}
	if code := Run(f.options(false, true, false)); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(f.out.String(), "Makefile") || exists(filepath.Join(f.folder, ".devzone.backup")) {
		t.Errorf("out = %q", f.out.String())
	}
}

// TestGitignoreCompletedKeepsCustomLines checks that a missing standard line is
// added back, the user's line stays, and no standard line is duplicated.
func TestGitignoreCompletedKeepsCustomLines(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	var kept []string
	data := f.read(f.folder, ".gitignore")
	for _, line := range strings.Split(data, "\n") {
		if line != ".devzone.backup/" {
			kept = append(kept, line)
		}
	}
	write(t, f.folder, ".gitignore", strings.Join(kept, "\n")+"mon-regle-a-moi\n")
	if code := Run(f.options(false, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	got := f.read(f.folder, ".gitignore")
	for _, want := range []string{"mon-regle-a-moi", ".devzone.backup/", "workspace/*"} {
		if !strings.Contains("\n"+got, "\n"+want+"\n") {
			t.Errorf(".gitignore lacks %q", want)
		}
	}
	if n := strings.Count("\n"+got, "\n.devzone.backup/\n"); n != 1 {
		t.Errorf(".devzone.backup/ appears %d times", n)
	}
}

// TestRebuildSuggestedWithoutTerminal checks that a folder of the former workstation (#735) gets the
// rebuild suggested on the terminal, and that nothing is run.
func TestRebuildSuggestedWithoutTerminal(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, ".devzone.modules", "workspace=ancien\n")
	if code := Run(f.options(true, false, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(f.out.String(), "make -C "+f.folder+" rebuild") || len(f.calls) != 0 {
		t.Errorf("out = %q, calls = %v", f.out.String(), f.calls)
	}
}

// TestNoRebuildNeverRebuilds checks that --no-rebuild stops the rebuild even when
// the terminal would answer yes.
func TestNoRebuildNeverRebuilds(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, ".devzone.modules", "workspace=ancien\n")
	f.answer = "y\n"
	if code := Run(f.options(true, true, true)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(f.out.String(), "Rebuild not started (--no-rebuild).") || len(f.calls) != 0 {
		t.Errorf("out = %q, calls = %v", f.out.String(), f.calls)
	}
}

// TestRebuildAnsweredYesRuns checks that a yes on the terminal runs the rebuild
// command, and that DEVZONE_REBUILD replaces the make call. Each case starts from
// a fresh folder: an updated folder would be up to date and never rebuild.
func TestRebuildAnsweredYesRuns(t *testing.T) {
	for _, tc := range []struct{ rebuild, want string }{
		{"", "make -C %s rebuild"},
		{"reconstruire", "sh -c reconstruire"},
	} {
		f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
		f.answer = "yes\n"
		opts := f.options(true, false, true)
		opts.RebuildCmd = tc.rebuild
		if code := Run(opts); code != 0 {
			t.Fatalf("code = %d", code)
		}
		want := f.folder + "|" + strings.ReplaceAll(tc.want, "%s", f.folder)
		if len(f.calls) != 1 || f.calls[0] != want {
			t.Errorf("rebuild %q: calls = %v, want %q", tc.rebuild, f.calls, want)
		}
	}
}

// TestKubernetesNeverOffersRebuild checks that a Kubernetes workstation is never
// offered a rebuild, even on a terminal, and that its mode line is kept.
func TestKubernetesNeverOffersRebuild(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, ".devzone.modules", "workspace=kubernetes\n")
	f.answer = "y\n"
	if code := Run(f.options(true, false, true)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	// The folder path holds the test name ("Rebuild"): it is removed before the check
	out := strings.ReplaceAll(f.out.String(), f.folder, "")
	if strings.Contains(out, "Rebuild") || strings.Contains(out, "make -C") || len(f.calls) != 0 {
		t.Errorf("out = %q, calls = %v", out, f.calls)
	}
	if f.read(f.folder, ".devzone.modules") != "workspace=kubernetes\n" {
		t.Error("the workstation mode was changed")
	}
}
