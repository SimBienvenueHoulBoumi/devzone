package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// argocdBashScript locates the shell original of Argo CD from this test file,
// like the other bash comparison tests, and skips the run without bash or on
// Windows.
func argocdBashScript(t *testing.T) (script, root string) {
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

// argocdBashHarness runs functions of the bash original in a folder that holds
// the fake kubectl and the modules file.
type argocdBashHarness struct {
	t      *testing.T
	dir    string
	script string
}

// newArgocdBashHarness prepares a folder with a fake kubectl that logs its
// arguments in FAKE_LOG and exits with FAKE_STATUS; a config get-contexts call
// prints FAKE_CONTEXTS and always succeeds.
func newArgocdBashHarness(t *testing.T) *argocdBashHarness {
	t.Helper()
	script, _ := argocdBashScript(t)
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	kubectl := `#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$*" in
*"config get-contexts"*) printf '%s' "${FAKE_CONTEXTS:-}"; exit 0 ;;
esac
exit "${FAKE_STATUS:-0}"
`
	if err := os.WriteFile(filepath.Join(dir, "bin", "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	return &argocdBashHarness{t: t, dir: dir, script: script}
}

// bashArgs sources the script in the harness folder, then runs body with values
// as the remaining arguments, and returns the standard output and the exit
// status of bash.
func (h *argocdBashHarness) bashArgs(body string, values []string, env ...string) (string, int) {
	h.t.Helper()
	args := append([]string{"-c", `. "$1"; ` + body, "_", h.script}, values...)
	cmd := exec.Command("bash", args...)
	cmd.Dir = h.dir
	cmd.Env = append(os.Environ(), "LC_ALL=C",
		"PATH="+filepath.Join(h.dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	cmd.Env = append(cmd.Env, env...)
	out, err := cmd.Output()
	status := 0
	if err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			h.t.Fatalf("cannot run bash: %v", err)
		}
		status = exitErr.ExitCode()
	}
	return string(out), status
}

// bash is bashArgs without extra arguments.
func (h *argocdBashHarness) bash(body string, env ...string) (string, int) {
	return h.bashArgs(body, nil, env...)
}

// readArgocdCalls returns the kubectl calls logged in path, without the
// config get-contexts call that only selects the context.
func readArgocdCalls(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var calls []string
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if line == "" || strings.Contains(line, "config get-contexts") {
			continue
		}
		calls = append(calls, line)
	}
	return calls
}

// addFakeKubectl puts the harness fake kubectl first in PATH and points it to
// log in log with the given status.
func (h *argocdBashHarness) addFakeKubectl(t *testing.T, log string, status int) {
	t.Setenv("FAKE_LOG", log)
	t.Setenv("FAKE_STATUS", strconv.Itoa(status))
	t.Setenv("PATH", filepath.Join(h.dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// TestArgocdInstalledMatchesBash compares the status of argocd_installed and
// argocdInstalled and the kubectl arguments they receive.
func TestArgocdInstalledMatchesBash(t *testing.T) {
	for _, status := range []int{0, 1} {
		t.Run("kubectl status "+strconv.Itoa(status), func(t *testing.T) {
			h := newArgocdBashHarness(t)
			bashLog := filepath.Join(t.TempDir(), "bash.log")
			goLog := filepath.Join(t.TempDir(), "go.log")
			_, bashStatus := h.bash(`kubectl_flag() { :; }; argocd_installed`,
				"FAKE_LOG="+bashLog, "FAKE_STATUS="+strconv.Itoa(status))
			h.addFakeKubectl(t, goLog, status)
			got := argocdInstalled(ExecRunner{})
			if (bashStatus == 0) != got {
				t.Fatalf("bash status %d, Go says %v", bashStatus, got)
			}
			want := []string{"get namespace devzone-argocd"}
			wantCalls(t, readArgocdCalls(t, bashLog), want...)
			wantCalls(t, readArgocdCalls(t, goLog), want...)
		})
	}
}

// TestArgocdActiveMatchesBash compares the status of argocd_active and
// argocdActive and the kubectl arguments they receive, including no call when
// argocd is off.
func TestArgocdActiveMatchesBash(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		modules string
		status  int
	}{
		{"wanted and installed", true, "argocd=on\n", 0},
		{"wanted and absent", true, "argocd=on\n", 1},
		{"off makes no call", true, "argocd=off\n", 0},
		{"missing modules", false, "", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newArgocdBashHarness(t)
			if tc.present {
				if err := os.WriteFile(filepath.Join(h.dir, modulesFile), []byte(tc.modules), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			bashLog := filepath.Join(t.TempDir(), "bash.log")
			goLog := filepath.Join(t.TempDir(), "go.log")
			_, bashStatus := h.bash(`kubectl_flag() { :; }; argocd_active`,
				"FAKE_LOG="+bashLog, "FAKE_STATUS="+strconv.Itoa(tc.status))
			h.addFakeKubectl(t, goLog, tc.status)
			got := argocdActive(ExecRunner{}, filepath.Join(h.dir, modulesFile))
			if (bashStatus == 0) != got {
				t.Fatalf("bash status %d, Go says %v", bashStatus, got)
			}
			want := []string{"get namespace devzone-argocd"}
			if tc.modules == "argocd=off\n" {
				want = nil
			}
			wantCalls(t, readArgocdCalls(t, bashLog), want...)
			wantCalls(t, readArgocdCalls(t, goLog), want...)
		})
	}
}

// TestArgocdQuantityKiMatchesBash compares argocd_quantity_ki and
// argocdQuantityKi on integer quantities only: the shell arithmetic fails on a
// decimal.
func TestArgocdQuantityKiMatchesBash(t *testing.T) {
	h := newArgocdBashHarness(t)
	values := []string{
		"1024Ki", "1Ki", "2Mi", "16384Mi", "1Gi", "1Ti", "1000K", "1000k",
		"1M", "1G", "2048", "0", "8049188Ki", "", "1000000",
	}
	out, status := h.bashArgs(`shift; for q in "$@"; do argocd_quantity_ki "$q"; done`, values)
	if status != 0 {
		t.Fatalf("bash status %d, output %q", status, out)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != len(values) {
		t.Fatalf("bash printed %d lines, want %d: %q", len(lines), len(values), out)
	}
	for i, q := range values {
		want := strconv.FormatInt(argocdQuantityKi(q), 10)
		if lines[i] != want {
			t.Fatalf("value %q: bash says %q, Go says %q", q, lines[i], want)
		}
	}
}

// TestArgocdRevisionMatchesBash compares argocd_revision and argocdRevision
// with the environment variable set or empty and with several package.json.
func TestArgocdRevisionMatchesBash(t *testing.T) {
	cases := []struct {
		name    string
		env     string
		present bool
		content string
	}{
		{"environment wins", "v9.9.9", true, `{"version": "1.2.3"}`},
		{"zero version", "", true, `{"version": "0.0.0"}`},
		{"real version", "", true, `{"version": "1.2.3"}`},
		{"empty version", "", true, `"version": ""`},
		{"no version field", "", true, `{"name": "devzone"}`},
		{"missing file", "", false, ""},
		{"first matching line wins", "", true,
			"{\n  \"version\": \"1.0.0\",\n  \"version\": \"2.0.0\"\n}"},
		{"last version on a line wins", "", true,
			`{"a": "version": "1.0.0", "version": "2.0.0"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newArgocdBashHarness(t)
			dir := t.TempDir()
			if tc.present {
				if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(tc.content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("DEVZONE_ARGOCD_REVISION", tc.env)
			out, status := h.bash(`argocd_revision`, "RACINE="+dir)
			if status != 0 {
				t.Fatalf("bash status %d, output %q", status, out)
			}
			if got := argocdRevision(dir); got != out {
				t.Fatalf("bash says %q, Go says %q", out, got)
			}
		})
	}
}
