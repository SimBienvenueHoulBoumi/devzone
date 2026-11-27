package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestVersionIsNewer checks dotted numeric comparison, missing components as 0
// and non-numeric components as 0, like the shell awk version.
func TestVersionIsNewer(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"0.20.0", "0.19.0", true},
		{"0.19.0", "0.20.0", false},
		{"0.19.0", "0.19.0", false},
		{"0.19", "0.19.0", false},
		{"0.19.1", "0.19", true},
		{"1.0.0", "1.0", false},
		{"1.0.1", "1.0", true},
		{"2", "1.9.9", true},
		{"1.10.0", "1.9.0", true},
		{"1.9.0", "1.10.0", false},
		{"1.2.3.4", "1.2.3", true},
		{"1.2.3", "1.2.3.4", false},
		{"v1.2.3", "1.2.3", false}, // awk +0 reads "v1" as 0; strip v first
	} {
		if got := versionIsNewer(tc.a, tc.b); got != tc.want {
			t.Errorf("versionIsNewer(%q, %q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

// TestAwkNumber checks the awk +0 conversion on individual components.
func TestAwkNumber(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want int
	}{
		{"3", 3}, {"03", 3}, {"3a", 3}, {"a", 0}, {"", 0}, {" 3", 3}, {"+3", 3}, {"-3", -3},
	} {
		if got := awkNumber(tc.in); got != tc.want {
			t.Errorf("awkNumber(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// runVersionAvailable runs version-available-line with a fake registry tool.
func runVersionAvailable(t *testing.T, published string) string {
	t.Helper()
	root := t.TempDir()
	home := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("HOME", home)
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	if err := os.WriteFile(filepath.Join(root, ".devzone.version"), []byte("version 0.19.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("npm", []string{"view", "devzone", "version"}, exec.Result{Stdout: []byte(published + "\n")})
	var out bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &bytes.Buffer{}, Runner: r}
	if code := versionAvailableLine(ctx); code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	return out.String()
}

// TestVersionAvailableLineNewer checks the printed line when published is newer.
func TestVersionAvailableLineNewer(t *testing.T) {
	out := runVersionAvailable(t, "0.20.0")
	want := "  ○ devzone 0.20.0 available: on the workstation, devzone update\n"
	if out != want {
		t.Fatalf("out = %q, want %q", out, want)
	}
}

// TestVersionAvailableLineStripsV checks a leading v on the published version.
func TestVersionAvailableLineStripsV(t *testing.T) {
	out := runVersionAvailable(t, "v0.20.0")
	if !bytes.Contains([]byte(out), []byte("devzone 0.20.0 available")) {
		t.Fatalf("out = %q, want stripped v", out)
	}
}

// TestVersionAvailableLineSameOrOlder checks silence when not newer.
func TestVersionAvailableLineSameOrOlder(t *testing.T) {
	if out := runVersionAvailable(t, "0.19.0"); out != "" {
		t.Fatalf("same version printed %q", out)
	}
	if out := runVersionAvailable(t, "0.18.0"); out != "" {
		t.Fatalf("older version printed %q", out)
	}
}

// TestVersionAvailableLineNoFolder checks no registry call without a manifest.
func TestVersionAvailableLineNoFolder(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	r := fake.New()
	var out bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &bytes.Buffer{}, Runner: r}
	if code := versionAvailableLine(ctx); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if out.Len() != 0 || len(r.Calls()) != 0 {
		t.Fatalf("out = %q calls = %d, want silence and no npm", out.String(), len(r.Calls()))
	}
}
