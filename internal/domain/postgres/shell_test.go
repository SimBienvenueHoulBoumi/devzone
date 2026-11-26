package postgres

import (
	"errors"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// shellRun sources a devzone shell library and runs a body with the given
// positional arguments. It is the Go equivalent of the bats tests that called
// the real shell functions with fake dependencies.
func shellRun(t *testing.T, script, body, stdin string, args ...string) (string, int) {
	t.Helper()
	return shellCommand(t, `. "$1"; `+body, stdin, append([]string{script}, args...))
}

// shellServices runs a body after sourcing the module and services libraries;
// the body arguments start at position six. The two empty slots keep those
// positions stable after the cluster scripts moved to Go, and a fake state
// dispatcher intercepts the `bash .../devzone state` calls of the libraries:
// writes, removals and initialisation go to ETAT with no real devzone binary,
// so the orchestration assertions still check the saved state.
func shellServices(t *testing.T, body, stdin string, args ...string) (string, int) {
	t.Helper()
	root := repoDevcontainer(t)
	scripts := []string{
		os.DevNull,
		os.DevNull,
		os.DevNull,
		filepath.Join(root, "devzone-modules.sh"),
		filepath.Join(root, "devzone-services.sh"),
	}
	program := `MODULES=(ai kubernetes gitlab postgres argocd mysql)
confirm_removal() { :; }
__test_state() {
    local action="$1" key="$2" value="$3" tmp
    case "$action" in
        init)
            [ -f "$ETAT" ] && return 0
            for key in "${@:2}"; do printf '%s=off\n' "$key"; done >"$ETAT"
            ;;
        write)
            [ -f "$ETAT" ] && cp "$ETAT" "$ETAT.prev"
            tmp="$ETAT.tmp.$$"
            { grep -vE "^${key}=" "$ETAT" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
            mv "$tmp" "$ETAT"
            ;;
        remove)
            [ -f "$ETAT" ] || return 0
            cp "$ETAT" "$ETAT.prev"
            tmp="$ETAT.tmp.$$"
            grep -vE "^${key}=" "$ETAT" >"$tmp" || true
            mv "$tmp" "$ETAT"
            ;;
        *) return 1 ;;
    esac
}
bash() {
    if [ "${2:-}" = state ]; then __test_state "${@:3}"; else command bash "$@"; fi
}
. "$1"; . "$2"; . "$3"; . "$4"; . "$5"; ` + body
	return shellCommand(t, program, stdin, append(scripts, args...))
}

// shellCommand runs a sourced bash program and reports its output and status.
func shellCommand(t *testing.T, program, stdin string, args []string) (string, int) {
	t.Helper()
	command := osexec.Command("bash", append([]string{"-c", program, "_"}, args...)...)
	command.Env = append(os.Environ(), "ETAT="+os.Getenv("DEVZONE_STATE"))
	command.Stdin = strings.NewReader(stdin)
	out, err := command.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	var exit *osexec.ExitError
	if !errors.As(err, &exit) {
		t.Fatalf("bash: %v", err)
	}
	return string(out), exit.ExitCode()
}

// writeState saves the lines of .devzone.modules for a shell orchestration test.
func writeState(t *testing.T, lines ...string) {
	t.Helper()
	path := filepath.Join(os.Getenv("DEVZONE_ROOT"), ".devzone.modules")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}
