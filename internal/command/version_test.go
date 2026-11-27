package command

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
)

// writePackage writes a package.json with the given body in folder
func writePackage(t *testing.T, folder, body string) {
	t.Helper()
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "package.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// setupPackage makes a package root with a package.json holding the version and
// a bash entry point, then points DEVZONE_BASH_ENTRY at that entry point
func setupPackage(t *testing.T, version string) string {
	t.Helper()
	root := t.TempDir()
	writePackage(t, root, `{"name": "devzone", "version": "`+version+`"}`)
	entryPoint := filepath.Join(root, "manage", "devzone")
	if err := os.MkdirAll(filepath.Dir(entryPoint), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entryPoint, []byte("exit 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(bashbridge.EnvVar, entryPoint)
	return root
}

func TestPackageVersionPresent(t *testing.T) {
	dir := t.TempDir()
	writePackage(t, dir, `{"name": "devzone", "version": "1.4.2"}`)
	if got := packageVersion([]string{dir}); got != "1.4.2" {
		t.Fatalf("packageVersion = %q, want 1.4.2", got)
	}
}

func TestPackageVersionAbsent(t *testing.T) {
	if got := packageVersion([]string{t.TempDir()}); got != "inconnue" {
		t.Fatalf("packageVersion = %q, want inconnue", got)
	}
}

func TestPackageVersionInvalidJSON(t *testing.T) {
	dir := t.TempDir()
	writePackage(t, dir, `{"version": "1.4.2",`)
	if got := packageVersion([]string{dir}); got != "inconnue" {
		t.Fatalf("packageVersion = %q, want inconnue", got)
	}
}

func TestPackageVersionSearchOrder(t *testing.T) {
	absent := t.TempDir()
	first := t.TempDir()
	second := t.TempDir()
	writePackage(t, first, `{"version": "1.0.0"}`)
	writePackage(t, second, `{"version": "2.0.0"}`)
	if got := packageVersion([]string{absent, first, second}); got != "1.0.0" {
		t.Fatalf("packageVersion = %q, want the first folder holding a package.json", got)
	}
	// An invalid file decides too: it is not skipped for the next folder
	writePackage(t, first, `not json`)
	if got := packageVersion([]string{first, second}); got != "inconnue" {
		t.Fatalf("packageVersion = %q, want inconnue", got)
	}
}

func TestVersionOfOtherValues(t *testing.T) {
	hostMode(t)
	cases := []struct {
		name, body, want string
	}{
		{"missing field", `{"name": "devzone"}`, "undefined"},
		{"empty string", `{"version": ""}`, ""},
		{"number", `{"version": 2}`, "2"},
		{"null", `{"version": null}`, "null"},
		{"top-level null", `null`, "inconnue"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := versionOf([]byte(c.body)); got != c.want {
				t.Fatalf("versionOf = %q, want %q", got, c.want)
			}
		})
	}
}

func TestPrintVersionAliases(t *testing.T) {
	hostMode(t)
	setupPackage(t, "1.4.2")
	for _, name := range []string{"--version", "-v"} {
		var out, errOut bytes.Buffer
		if got := Run([]string{name}, &out, &errOut); got != 0 {
			t.Fatalf("%s: exit status = %d, want 0", name, got)
		}
		if out.String() != "1.4.2\n" {
			t.Fatalf("%s: stdout = %q, want the version and a newline", name, out.String())
		}
		if errOut.Len() != 0 {
			t.Fatalf("%s: stderr = %q, want nothing", name, errOut.String())
		}
	}
}

func TestVersionWithArgumentIsDelegated(t *testing.T) {
	hostMode(t)
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out bytes.Buffer
	if got := Run([]string{"-v", "x"}, &out, &bytes.Buffer{}); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if out.String() != "args:[-v][x]\n" {
		t.Fatalf("stdout = %q, want the command line passed to bash", out.String())
	}
}
