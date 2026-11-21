package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestExecRunnerKubectlMissing(t *testing.T) {
	// An empty PATH: kubectl cannot be found, which is an error, not an exit status
	t.Setenv("PATH", t.TempDir())
	status, err := ExecRunner{}.Kubectl([]string{"version"}, nil, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || status != 0 {
		t.Fatalf("status %d, err %v: want an error and no status", status, err)
	}
}

func TestExecRunnerExitStatusAndOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	dir := t.TempDir()
	script := "#!/bin/sh\necho out\necho err >&2\nexit 3\n"
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	var out, errOut bytes.Buffer
	status, err := ExecRunner{}.Kubectl([]string{"get", "pods"}, nil, &out, &errOut)
	if err != nil || status != 3 {
		t.Fatalf("status %d, err %v: want status 3 and no error", status, err)
	}
	if out.String() != "out\n" || errOut.String() != "err\n" {
		t.Fatalf("stdout %q, stderr %q", out.String(), errOut.String())
	}
}

func TestExecRunnerPassesStdinOn(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte("#!/bin/sh\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	// A file stands for the terminal: kubectl exec -it reads the user input from the same descriptor
	in, err := os.Create(filepath.Join(t.TempDir(), "input"))
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	if _, err := in.WriteString("typed\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := in.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	status, err := ExecRunner{}.Kubectl([]string{"exec", "-it"}, in, &out, &bytes.Buffer{})
	if err != nil || status != 0 || out.String() != "typed\n" {
		t.Fatalf("status %d, err %v, stdout %q: want the input read by kubectl", status, err, out.String())
	}
}
