package bashbridge

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// requireBash skips the test when bash cannot run the scripts (Windows, or not
// installed)
func requireBash(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("bash tests run on Unix only")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not installed")
	}
}

// writeScript writes a script with the given body in a temporary folder and
// returns its path
func writeScript(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "entry.sh")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRunExitStatus(t *testing.T) {
	requireBash(t)
	cases := []struct {
		name string
		body string
		want int
	}{
		{"success", "exit 0\n", 0},
		{"custom code", "exit 7\n", 7},
		{"command not found", "no-such-command-devzone-test\n", 127},
		{"killed by SIGTERM", "kill -TERM $$\n", 143},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Run(writeScript(t, c.body), nil, nil, &bytes.Buffer{}, &bytes.Buffer{})
			if got != c.want {
				t.Fatalf("exit status = %d, want %d", got, c.want)
			}
		})
	}
}

func TestRunNotExecutable(t *testing.T) {
	requireBash(t)
	noexec := filepath.Join(t.TempDir(), "noexec")
	if err := os.WriteFile(noexec, []byte("echo never\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	script := writeScript(t, "\""+noexec+"\"\n")
	got := Run(script, nil, nil, &bytes.Buffer{}, &bytes.Buffer{})
	if got != 126 {
		t.Fatalf("exit status = %d, want 126", got)
	}
}

func TestRunStreams(t *testing.T) {
	requireBash(t)
	script := writeScript(t, "echo out-line\necho err-line >&2\n")
	var out, errOut bytes.Buffer
	if got := Run(script, nil, nil, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if out.String() != "out-line\n" {
		t.Errorf("stdout = %q", out.String())
	}
	if errOut.String() != "err-line\n" {
		t.Errorf("stderr = %q", errOut.String())
	}
}

func TestRunArguments(t *testing.T) {
	requireBash(t)
	script := writeScript(t, "printf '%s\\n' \"$#\"; for a in \"$@\"; do printf '[%s]\\n' \"$a\"; done\n")
	var out bytes.Buffer
	if got := Run(script, []string{"one", "two words", ""}, nil, &out, &bytes.Buffer{}); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	want := "3\n[one]\n[two words]\n[]\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

func TestRunStdin(t *testing.T) {
	requireBash(t)
	script := writeScript(t, "cat\n")
	var out bytes.Buffer
	Run(script, nil, strings.NewReader("hello stdin\n"), &out, &bytes.Buffer{})
	if out.String() != "hello stdin\n" {
		t.Fatalf("stdout = %q, want the stdin text", out.String())
	}
}

func TestRunInheritsEnvironment(t *testing.T) {
	requireBash(t)
	t.Setenv("DEVZONE_BRIDGE_TEST", "inherited")
	script := writeScript(t, "printf '%s' \"$DEVZONE_BRIDGE_TEST\"\n")
	var out bytes.Buffer
	Run(script, nil, nil, &out, &bytes.Buffer{})
	if out.String() != "inherited" {
		t.Fatalf("stdout = %q, want the inherited variable", out.String())
	}
}

func TestRunInheritsWorkingDirectory(t *testing.T) {
	requireBash(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	script := writeScript(t, "pwd -P\n")
	var out bytes.Buffer
	Run(script, nil, nil, &out, &bytes.Buffer{})
	if strings.TrimSpace(out.String()) != dir {
		t.Fatalf("pwd = %q, want %q", out.String(), dir)
	}
}
