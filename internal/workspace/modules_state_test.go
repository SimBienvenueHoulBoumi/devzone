package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stateCase is one starting file and the result of writing key=value in it.
type stateCase struct {
	name    string
	present bool
	content string
	key     string
	value   string
	want    string
}

var stateCases = []stateCase{
	{"missing file", false, "", "argocd", "on", "argocd=on\n"},
	{"key added at the end", true, "postgres=on\nmysql=off\n", "argocd", "on", "postgres=on\nmysql=off\nargocd=on\n"},
	{"old key moved to the end", true, "postgres=on\nargocd=off\nmysql=on\n", "argocd", "on", "postgres=on\nmysql=on\nargocd=on\n"},
	{"all duplicates removed", true, "argocd=off\npostgres=on\nargocd=on\nargocd=maybe\n", "argocd", "on", "postgres=on\nargocd=on\n"},
	{"empty lines kept", true, "\npostgres=on\n\nargocd=off\n\n", "argocd", "on", "\npostgres=on\n\n\nargocd=on\n"},
	{"last line without newline", true, "postgres=on\nargocd=off", "argocd", "on", "postgres=on\nargocd=on\n"},
	{"empty value", true, "other=1\n", "argocd", "", "other=1\nargocd=\n"},
	{"value with equal signs", true, "other=1\n", "argocd", "a=b=c", "other=1\nargocd=a=b=c\n"},
	{"longer key kept", true, "argocd_x=on\nmysql=off\n", "argocd", "on", "argocd_x=on\nmysql=off\nargocd=on\n"},
	{"carriage returns kept", true, "postgres=on\r\nargocd=off\r\nother=1\r\n", "argocd", "on", "postgres=on\r\nother=1\r\nargocd=on\n"},
}

func writeStateFile(t *testing.T, dir, content string) string {
	t.Helper()
	path := filepath.Join(dir, modulesFile)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestReadModulesKey checks the last match, the first equal sign, the
// unchanged value and the empty answers of readModulesKey.
func TestReadModulesKey(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		content string
		key     string
		want    string
	}{
		{"missing file", false, "", "argocd", ""},
		{"absent key", true, "postgres=on\nargocd=off\n", "gitlab", ""},
		{"one line", true, "argocd=on\n", "argocd", "on"},
		{"last duplicate wins", true, "argocd=on\npostgres=1\nargocd=off\n", "argocd", "off"},
		{"value with equal signs", true, "argocd=a=b=c\n", "argocd", "a=b=c"},
		{"empty value", true, "argocd=\n", "argocd", ""},
		{"other key with this prefix", true, "argocd=on\n", "argo", ""},
		{"shorter key", true, "argocd_x=on\nargo=off\n", "argo", "off"},
		{"last line without newline", true, "postgres=on\nargocd=off", "argocd", "off"},
		{"blank line in the middle", true, "argocd=on\n\npostgres=on\n", "postgres", "on"},
		{"carriage return kept", true, "argocd=on\r\n", "argocd", "on\r"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if tc.present {
				writeStateFile(t, dir, tc.content)
			}
			got := readModulesKey(filepath.Join(dir, modulesFile), tc.key)
			if got != tc.want {
				t.Fatalf("key %q: got %q, want %q", tc.key, got, tc.want)
			}
		})
	}
}

// TestNoteModulesKey checks the order of the kept lines, the removal of all
// matches, the appended line and the absence of a temporary file.
func TestNoteModulesKey(t *testing.T) {
	for _, tc := range stateCases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			var path string
			if tc.present {
				path = writeStateFile(t, dir, tc.content)
			} else {
				path = filepath.Join(dir, modulesFile)
			}
			if err := noteModulesKey(path, tc.key, tc.value); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(data) != tc.want {
				t.Fatalf("got %q, want %q", data, tc.want)
			}
			entries, err := os.ReadDir(dir)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), modulesFile+".tmp.") {
					t.Fatalf("temporary file left: %s", entry.Name())
				}
			}
		})
	}
}

// TestNoteModulesKeyMode checks the mode of a file created by noteModulesKey.
func TestNoteModulesKeyMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, modulesFile)
	if err := noteModulesKey(path, "argocd", "on"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("mode is %04o, want 0644", got)
	}
}
