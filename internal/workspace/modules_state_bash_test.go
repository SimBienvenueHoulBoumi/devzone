package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// stateBashScript locates the shell original from this test file, like the
// other bash comparison tests, and skips the run without bash or on Windows.
func stateBashScript(t *testing.T) (script, root string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the bash original does not run on Windows")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test file")
	}
	root = filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
	return filepath.Join(root, "manage", "scripts", "workspace", "argocd-workspace.sh"), root
}

// runStateBash sources the shell original in dir, then runs body with key and
// value as the third and fourth arguments, and returns its standard output.
func runStateBash(t *testing.T, dir, script, root, body, key, value string) string {
	t.Helper()
	cmd := exec.Command("bash", "-c", `cd "$1" && source "$2" && `+body, "_", dir, script, key, value)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "RACINE="+root)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash failed: %v\n%s", err, out)
	}
	return string(out)
}

// TestModulesStateMatchesBashWrite compares the bytes written by state_note
// with the bytes written by noteModulesKey from the same starting content.
func TestModulesStateMatchesBashWrite(t *testing.T) {
	script, root := stateBashScript(t)
	for _, tc := range stateCases {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			bashDir := filepath.Join(base, "bash")
			goDir := filepath.Join(base, "go")
			for _, dir := range []string{bashDir, goDir} {
				if err := os.Mkdir(dir, 0o755); err != nil {
					t.Fatal(err)
				}
				if tc.present {
					writeStateFile(t, dir, tc.content)
				}
			}
			runStateBash(t, bashDir, script, root, `state_note "$3" "$4"`, tc.key, tc.value)
			if err := noteModulesKey(filepath.Join(goDir, modulesFile), tc.key, tc.value); err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(filepath.Join(bashDir, modulesFile))
			if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(filepath.Join(goDir, modulesFile))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("bash wrote %q, Go wrote %q", want, got)
			}
		})
	}
}

// TestModulesStateMatchesBashRead compares the output of state_read with the
// value returned by readModulesKey from the same starting content. The shell
// prints a final newline that command substitution removes, so only those
// final newlines are trimmed from the captured output.
func TestModulesStateMatchesBashRead(t *testing.T) {
	script, root := stateBashScript(t)
	cases := append([]stateCase{
		{"missing file", false, "", "argocd", "on", ""},
		{"absent key", true, "postgres=on\n", "gitlab", "", ""},
		{"last duplicate wins", true, "argocd=on\nother=1\nargocd=off\n", "argocd", "", ""},
		{"key prefix of another", true, "argocd=on\n", "argo", "", ""},
		{"read value with equal signs", true, "argocd=a=b=c\n", "argocd", "", ""},
		{"blank line in the middle", true, "argocd=on\n\npostgres=on\n", "postgres", "", ""},
		{"shorter key", true, "argocd_x=on\nargo=off\n", "argo", "", ""},
	}, stateCases...)
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			bashDir := filepath.Join(base, "bash")
			goDir := filepath.Join(base, "go")
			for _, dir := range []string{bashDir, goDir} {
				if err := os.Mkdir(dir, 0o755); err != nil {
					t.Fatal(err)
				}
				if tc.present {
					writeStateFile(t, dir, tc.content)
				}
			}
			want := strings.TrimRight(runStateBash(t, bashDir, script, root, `state_read "$3"`, tc.key, ""), "\n")
			got := readModulesKey(filepath.Join(goDir, modulesFile), tc.key)
			if got != want {
				t.Fatalf("key %q: bash says %q, Go says %q", tc.key, want, got)
			}
		})
	}
}
