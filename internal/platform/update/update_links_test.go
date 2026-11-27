package update

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// poisonedFixture installs v1, then adds to the manifest a line naming rel with a
// zero checksum, as a hand-edited or hostile manifest would. A secret file sits
// outside the devzone folder, where a refused path must never reach.
func poisonedFixture(t *testing.T, rel string) (*fixture, string) {
	t.Helper()
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	outside := filepath.Join(filepath.Dir(f.folder), "dehors")
	write(t, outside, "secret", "secret\n")
	line := fmt.Sprintf("%064d  %s\n", 0, rel)
	appendFile(t, filepath.Join(f.folder, manifest.FileName), line)
	return f, outside
}

// appendFile adds text at the end of the file path.
func appendFile(t *testing.T, path, text string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, text...), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestPoisonedManifestPathsRefused checks that each path a hostile manifest names
// outside the devzone is refused with a message, and the file behind it survives.
func TestPoisonedManifestPathsRefused(t *testing.T) {
	for _, rel := range []string{"../dehors/secret", "/etc/x", "a/../../dehors/secret", ".devcontainer/../../dehors/secret"} {
		f, outside := poisonedFixture(t, rel)
		if code := Run(f.options(true, true, false)); code != 0 {
			t.Errorf("%s: code = %d, stderr = %q", rel, code, f.errOut.String())
		}
		if got, _ := os.ReadFile(filepath.Join(outside, "secret")); string(got) != "secret\n" {
			t.Errorf("%s: the file outside was changed", rel)
		}
		if !strings.Contains(f.errOut.String(), "devzone: manifest: refused path: "+rel+"\n") {
			t.Errorf("%s: no refusal in %q", rel, f.errOut.String())
		}
	}
}

// TestPoisonedManifestOutsideManagedFoldersRefused checks that a path inside the
// folder but outside the folders the package manages (workspace/) is refused and
// the user's file there is kept.
func TestPoisonedManifestOutsideManagedFoldersRefused(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, "workspace/x", "a moi\n")
	appendFile(t, filepath.Join(f.folder, manifest.FileName), fmt.Sprintf("%064d  workspace/x\n", 0))
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.read(f.folder, "workspace/x") != "a moi\n" {
		t.Error("the user's workspace file was changed")
	}
	if !strings.Contains(f.errOut.String(), "devzone: manifest: refused path: workspace/x") {
		t.Errorf("no refusal in %q", f.errOut.String())
	}
}

// TestPoisonedManifestOutgoingLinkRefused checks that a manifest path that goes
// through a link pointing outside the devzone is refused: the file behind the link
// is never removed nor written.
func TestPoisonedManifestOutgoingLinkRefused(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	outside := filepath.Join(filepath.Dir(f.folder), "dehors")
	write(t, outside, "secret", "secret\n")
	if err := os.Symlink(outside, filepath.Join(f.folder, ".devcontainer/lien")); err != nil {
		t.Skip("symbolic links not available:", err)
	}
	appendFile(t, filepath.Join(f.folder, manifest.FileName), fmt.Sprintf("%064d  .devcontainer/lien/secret\n", 0))
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if got, _ := os.ReadFile(filepath.Join(outside, "secret")); string(got) != "secret\n" {
		t.Error("the file behind the outgoing link was changed")
	}
	if !strings.Contains(f.errOut.String(), "refused path: .devcontainer/lien/secret") {
		t.Errorf("no refusal in %q", f.errOut.String())
	}
}

// TestLinkOnPackageFileReplacedTargetIntact checks that a link where the package
// writes a file is replaced by a real file, and the link's target is untouched.
func TestLinkOnPackageFileReplacedTargetIntact(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	target := filepath.Join(filepath.Dir(f.folder), "dehors", "cible")
	write(t, filepath.Dir(target), "cible", "intact\n")
	json := filepath.Join(f.folder, ".devcontainer/devcontainer.json")
	if err := os.Remove(json); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, json); err != nil {
		t.Skip("symbolic links not available:", err)
	}
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errOut.String())
	}
	if got, _ := os.ReadFile(target); string(got) != "intact\n" {
		t.Error("the target of the link was written")
	}
	if info, err := os.Lstat(json); err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Error("the link was not replaced by a real file")
	}
	if f.read(f.folder, ".devcontainer/devcontainer.json") != "{\"marque\":\"nouveau\"}\n" {
		t.Error("the replaced file has the wrong content")
	}
	if !strings.Contains(f.errOut.String(), "link replaced: .devcontainer/devcontainer.json") {
		t.Errorf("no notice in %q", f.errOut.String())
	}
}

// TestBackupKeepsLinkNotTarget checks that the backup of a link is a link: a copy
// of the target could leak a file from outside the devzone.
func TestBackupKeepsLinkNotTarget(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	target := filepath.Join(filepath.Dir(f.folder), "dehors", "cible")
	write(t, filepath.Dir(target), "cible", "intact\n")
	json := filepath.Join(f.folder, ".devcontainer/devcontainer.json")
	if err := os.Remove(json); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, json); err != nil {
		t.Skip("symbolic links not available:", err)
	}
	if code := Run(f.options(true, true, false)); code != 0 {
		t.Fatalf("code = %d", code)
	}
	info, err := os.Lstat(filepath.Join(f.backupDir(), ".devcontainer/devcontainer.json"))
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the backup is not a link: %v", err)
	}
}

// TestPortWatcherRestartedOnceThenSignalRemoved checks that the restart signal of
// the port watcher starts it again in the folder, and that the signal is removed.
func TestPortWatcherRestartedOnceThenSignalRemoved(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	marker := filepath.Join(f.folder, ".devzone.workspace-ports", "restart")
	write(t, f.folder, ".devzone.workspace-ports/restart", "")
	opts := f.options(true, true, false)
	opts.PortsCmd = "pwd >>restart.log"
	if code := Run(opts); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if len(f.calls) != 1 || f.calls[0] != f.folder+"|sh -c pwd >>restart.log" {
		t.Errorf("calls = %v", f.calls)
	}
	if exists(marker) {
		t.Error("the restart signal was kept")
	}
}

// TestPortWatcherNotStartedWithoutSignal checks that a watcher the user stopped is
// never started: without the signal the update runs no command for it.
func TestPortWatcherNotStartedWithoutSignal(t *testing.T) {
	f := newFixture(t, newPackage(t, "0.0.1", "ancien"), newPackage(t, "0.0.2", "nouveau"))
	write(t, f.folder, ".devzone.workspace-ports/keep", "")
	opts := f.options(true, true, false)
	opts.PortsCmd = "pwd >>restart.log"
	if code := Run(opts); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if len(f.calls) != 0 {
		t.Errorf("calls = %v", f.calls)
	}
}
