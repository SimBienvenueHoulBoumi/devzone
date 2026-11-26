package state

import (
	"bytes"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestShellRecoveryGoEquivalent compares the recovery marker predicates and
// their exit codes with the shell functions.
func TestShellRecoveryGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	shellPath, goPath := stateCopies(t, "ai=on\n")
	shellOut, shellCode := shellState(t, script, shellPath, `state_recovery_mark`)
	goState, goCode := At(goPath), numericCode(At(goPath).RecoveryMark())
	compareCodes(t, "mark", shellCode, goCode)
	if shellOut != "" {
		t.Fatalf("unexpected shell output: %q", shellOut)
	}
	for _, path := range []string{shellPath + ".recouvre", goPath + ".recouvre"} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64); err != nil {
			t.Fatalf("marker %s: %q", path, data)
		}
	}
	_, waitCode := shellState(t, script, shellPath, `state_recovery_wait`)
	compareCodes(t, "wait recent", waitCode, numericCodeFromBool(goState.RecoveryWait()))
	_, pendingCode := shellState(t, script, shellPath, `state_recovery_pending`)
	compareCodes(t, "pending", pendingCode, numericCodeFromBool(goState.RecoveryPending()))

	old := strconv.FormatInt(time.Now().Add(-120*time.Second).Unix(), 10)
	for _, path := range []string{shellPath + ".recouvre", goPath + ".recouvre"} {
		if err := os.WriteFile(path, []byte(old), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	_, waitCode = shellState(t, script, shellPath, `state_recovery_wait`)
	compareCodes(t, "wait old", waitCode, numericCodeFromBool(goState.RecoveryWait()))

	_, shellCode = shellState(t, script, shellPath, `state_recovery_confirm`)
	compareCodes(t, "confirm", shellCode, numericCode(goState.RecoveryConfirm()))
	for _, path := range []string{shellPath + ".recouvre", goPath + ".recouvre"} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("marker remains: %s (%v)", path, err)
		}
	}
}

// numericCodeFromBool turns a shell predicate result into an exit code.
func numericCodeFromBool(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

// TestShellInitGoEquivalent compares creation, restore, rebuild and migration
// with a fake kubectl, never a real cluster.
func TestShellInitGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	writeShellFake(t, filepath.Join(bin, "kubectl"), `#!/usr/bin/env bash
case "$*" in
    get\ namespaces*) for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done ;;
    *"config view"*) for c in devzone docker-desktop; do case "$*" in *"$c"*) echo docker-desktop; exit 0 ;; esac; done; exit 1 ;;
    "config get-contexts -o name") printf 'devzone\ndocker-desktop\n' ;;
    *) exit 1 ;;
esac
exit 0
`)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(dir, "host.config"))
	home := filepath.Join(dir, "home")
	t.Setenv("HOME", home)
	modules := []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}

	cases := []struct {
		name string
		prev string
		env  string
	}{
		{name: "first install"},
		{name: "restore backup", prev: "ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n"},
		{name: "rebuild namespaces", env: "devzone-postgres devzone-gitlab"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("FAUX_NS", tc.env)
			shellPath, goPath := stateCopies(t, "")
			if tc.prev != "" {
				for _, path := range []string{shellPath + ".prev", goPath + ".prev"} {
					writeShellFake(t, path, tc.prev)
				}
			}
			program := `. "$1"; ETAT="$2"; state_init ` + strings.Join(modules, " ")
			shellOut, shellCode := shellCommandArgs(t, script, shellPath, program, nil)
			var warns []string
			goCode := numericCode(At(goPath).Init(modules, shellRunner(), shellPath+".home", nil, func(m string) { warns = append(warns, m) }))
			compareCodes(t, tc.name, shellCode, goCode)
			compareStateBytes(t, shellPath, goPath)
			wantWarns := strings.ReplaceAll(shellOut, shellPath, "<STATE>")
			gotWarns := strings.Join(warns, "\n")
			if len(warns) > 0 {
				gotWarns += "\n"
			}
			gotWarns = strings.ReplaceAll(gotWarns, goPath, "<STATE>")
			if wantWarns != gotWarns {
				t.Fatalf("warnings differ: shell=%q Go=%q", wantWarns, gotWarns)
			}
		})
	}
}

// shellCommandArgs runs a shell program with the modules as positional arguments.
func shellCommandArgs(t *testing.T, script, statePath, program string, args []string) (string, int) {
	t.Helper()
	cmdArgs := append([]string{"-c", program, "_", script, statePath}, args...)
	cmd := osexec.Command("bash", cmdArgs...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if err == nil {
		return out.String(), 0
	}
	if exit, ok := err.(*osexec.ExitError); ok {
		return out.String(), exit.ExitCode()
	}
	t.Fatalf("bash: %v", err)
	return "", -1
}

// writeShellFake writes a fake command or data file in a disposable folder.
func writeShellFake(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

// shellRunner adapts the fake kubectl in PATH to the state Runner signature.
func shellRunner() Runner {
	return func(name string, args ...string) (string, string, error) {
		cmd := osexec.Command(name, args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		err := cmd.Run()
		return stdout.String(), stderr.String(), err
	}
}

// TestShellAbortGoEquivalent checks that a failed write leaves the state, no
// temporary file and no lock, as state_abort does.
func TestShellAbortGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	shellPath, goPath := stateCopies(t, "ai=on\n")
	tmp := filepath.Join(filepath.Dir(shellPath), "shell.tmp")
	_, shellCode := shellState(t, script, shellPath, `state_lock_take; printf x >"$3"; state_abort "$3"`, tmp)
	if shellCode != 1 {
		t.Fatalf("shell abort code %d", shellCode)
	}
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Fatalf("temp remains: %v", err)
	}
	if err := os.Mkdir(goPath+".prev", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := At(goPath).Set("ai", "off"); err == nil {
		t.Fatal("Go write should fail when the backup path is a directory")
	}
	compareStateBytes(t, shellPath, goPath)
	if _, err := os.Stat(goPath + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("Go lockdir remains: %v", err)
	}
}

// TestShellHostContextGoEquivalent checks the host context selected for a
// services cluster, using only the fake kubectl script.
func TestShellHostContextGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	writeShellFake(t, filepath.Join(bin, "kubectl"), `#!/usr/bin/env bash
case "$*" in
    "config get-contexts -o name") printf 'devzone\ndocker-desktop\n' ;;
    *docker-desktop*) echo docker-desktop ;;
    *) exit 1 ;;
esac
exit 0
`)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(dir, "host.config"))
	shellPath, _ := stateCopies(t, "ai=on\n")
	out, code := shellState(t, script, shellPath, `host_context_of_cluster "$3"`, "docker-desktop")
	if code != 0 {
		t.Fatalf("shell host context code %d: %q", code, out)
	}
	if got := hostContextOfCluster(shellRunner(), "docker-desktop"); got != strings.TrimSpace(out) {
		t.Fatalf("host context: shell=%q Go=%q", out, got)
	}
}
