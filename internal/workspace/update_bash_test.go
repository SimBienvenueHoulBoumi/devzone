package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// updateScript is the bash original of the workspace update, sourced by
// manage/workspace.sh.
const updateScript = "../../manage/scripts/workspace/workspace-update.sh"

// TestLatestVersionMatchesBash compares the stable release chosen by the shell
// (git ls-remote, sort -V, tail -1) with LatestVersion and GitTags, with a fake
// git in the PATH and no repository behind it.
func TestLatestVersionMatchesBash(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the bash original does not run on Windows")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	refs := "abc\tdeadbee\tdevelop\n" +
		"def\tfeedface\trefs/tags/v0.9.0\n" +
		"aaa\tabcdef01\trefs/tags/v0.48.0\n" +
		"bbb\tabcdef02\trefs/tags/v0.48.0-rc1\n" +
		"ccc\tabcdef03\trefs/tags/v1.10.0\n"
	git := "#!/usr/bin/env bash\nprintf '%s' \"$FAKE_REFS\"\n"
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(git), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_REFS", refs)
	t.Setenv("DEVZONE_REPO_URL", imageRepository)
	path, err := filepath.Abs(updateScript)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", `. "$1"; update_latest_version`, "_", path)
	cmd.Dir = dir
	want, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash failed: %v", err)
	}
	got := LatestVersion(GitTags(imageRepository))
	if strings.TrimSpace(string(want)) != got {
		t.Fatalf("bash says %q, Go says %q", strings.TrimSpace(string(want)), got)
	}
}
