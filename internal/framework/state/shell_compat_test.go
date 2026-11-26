package state

import (
	"bytes"
	"os"
	osexec "os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// shellScript extracts one state script from origin/develop into a temp folder
// so the Go tests can call the real shell functions they replace.
func shellScript(t *testing.T, name string) string {
	t.Helper()
	_, here, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(here), "..", "..", ".."))
	dir := t.TempDir()
	names := []string{name}
	if name == "state.sh" {
		names = append(names, "state-lock.sh")
	}
	for _, scriptName := range names {
		out, err := osexec.Command("git", "-C", repo, "show", "origin/develop:.devcontainer/"+scriptName).Output()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, scriptName), out, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(dir, name)
}

// shellState calls a function of the real state.sh with its state file as a
// positional argument, never by escaping data into the shell program.
func shellState(t *testing.T, script, statePath, body string, args ...string) (string, int) {
	t.Helper()
	program := `. "$1"; ETAT="$2"; ` + body
	cmdArgs := append([]string{"-c", program, "_", script, statePath}, args...)
	cmd := osexec.Command("bash", cmdArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return stdout.String() + stderr.String(), 0
	}
	if exit, ok := err.(*osexec.ExitError); ok {
		return stdout.String() + stderr.String(), exit.ExitCode()
	}
	t.Fatalf("bash: %v", err)
	return "", -1
}

// stateCopies creates two disposable state files with the same initial content.
func stateCopies(t *testing.T, content string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	shellPath := filepath.Join(dir, "shell.modules")
	goPath := filepath.Join(dir, "go.modules")
	if content != "" {
		if err := os.WriteFile(shellPath, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goPath, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return shellPath, goPath
}

// compareStateBytes compares the two states produced by the shell and the Go code.
func compareStateBytes(t *testing.T, shellPath, goPath string) {
	t.Helper()
	want, err := os.ReadFile(shellPath)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	got, err := os.ReadFile(goPath)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if !bytes.Equal(want, got) {
		t.Fatalf("state differs: shell=%q Go=%q", want, got)
	}
}

// compareCodes compares the shell and Go exit codes of the same operation.
func compareCodes(t *testing.T, name string, shellCode, goCode int) {
	t.Helper()
	if shellCode != goCode {
		t.Fatalf("%s: shell code %d, Go code %d", name, shellCode, goCode)
	}
}

// TestShellWriteRemoveReplaceGoEquivalent checks the shell and Go results of
// writing, removing, replacing, copying and filtering the state file.
func TestShellWriteRemoveReplaceGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	type operation struct {
		name    string
		initial string
		body    string
		args    []string
		apply   func(s *State, args []string) error
	}
	ops := []operation{
		{name: "write missing state", body: `state_write "$3" "$4"`, args: []string{"ai", "on"},
			apply: func(s *State, a []string) error { return s.Set(a[0], a[1]) }},
		{name: "write replaces only its key", initial: "unknown line\nai=off\nkubernetes=off\n", body: `state_write "$3" "$4"`, args: []string{"ai", "on"},
			apply: func(s *State, a []string) error { return s.Set(a[0], a[1]) }},
		{name: "remove existing key", initial: "ai=on\nkubernetes=off\n", body: `state_remove "$3"`, args: []string{"ai"},
			apply: func(s *State, a []string) error { return s.Delete(a[0]) }},
		{name: "remove absent key", initial: "ai=on\n", body: `state_remove "$3"`, args: []string{"mysql"},
			apply: func(s *State, a []string) error { return s.Delete(a[0]) }},
		{name: "remove without state", body: `state_remove "$3"`, args: []string{"ai"},
			apply: func(s *State, a []string) error { return s.Delete(a[0]) }},
	}
	for _, op := range ops {
		t.Run(op.name, func(t *testing.T) {
			shellPath, goPath := stateCopies(t, op.initial)
			shellOut, shellCode := shellState(t, script, shellPath, op.body, op.args...)
			goCode := 0
			if err := op.apply(At(goPath), op.args); err != nil {
				goCode = 1
			}
			if shellCode != goCode {
				t.Fatalf("%s: shell code %d (%q), Go code %d", op.name, shellCode, shellOut, goCode)
			}
			compareStateBytes(t, shellPath, goPath)
		})
	}
}

// TestShellBackupReplaceFilterGoEquivalent checks the whole-file operations.
func TestShellBackupReplaceFilterGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	dir := t.TempDir()
	source := filepath.Join(dir, "source")
	if err := os.WriteFile(source, []byte("cluster=kind-devzone\nai=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	initial := "ai=off\nkubernetes=on\n"
	shellPath, goPath := stateCopies(t, initial)
	_, shellCode := shellState(t, script, shellPath, `state_replace "$3"`, source)
	goCode := 0
	if err := At(goPath).Replace(source); err != nil {
		goCode = 1
	}
	compareCodes(t, "replace", shellCode, goCode)
	compareStateBytes(t, shellPath, goPath)
	compareFiles(t, shellPath+".prev", goPath+".prev")

	shellPath, goPath = stateCopies(t, initial)
	_, shellCode = shellState(t, script, shellPath, `state_backup`)
	goCode = 0
	if err := At(goPath).backupLocked(); err != nil {
		goCode = 1
	}
	compareCodes(t, "backup", shellCode, goCode)
	compareFiles(t, shellPath+".prev", goPath+".prev")

	content := "ai=on\nunknown\nai=off\nkubernetes=off\n"
	shellPath, goPath = stateCopies(t, content)
	shellDst, goDst := filepath.Join(dir, "shell.filtered"), filepath.Join(dir, "go.filtered")
	_, shellCode = shellState(t, script, shellPath, `state_filter "$3" "$4"`, "ai", shellDst)
	lines, err := At(goPath).filteredLines("ai")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(goDst, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	compareCodes(t, "filter", shellCode, 0)
	compareFiles(t, shellDst, goDst)
}

// compareFiles compares two files or their common absence.
func compareFiles(t *testing.T, want, got string) {
	t.Helper()
	left, errLeft := os.ReadFile(want)
	right, errRight := os.ReadFile(got)
	if (errLeft == nil) != (errRight == nil) {
		t.Fatalf("files differ: %s (%v), %s (%v)", want, errLeft, got, errRight)
	}
	if errLeft == nil && !bytes.Equal(left, right) {
		t.Fatalf("files differ: %q vs %q", left, right)
	}
}

// numericCode returns 0 or 1 from an error, like a shell predicate.
func numericCode(err error) int {
	if err != nil {
		return 1
	}
	return 0
}
