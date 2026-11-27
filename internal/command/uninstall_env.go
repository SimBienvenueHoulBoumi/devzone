package command

import (
	"fmt"
	"os"
	"strings"
)

// uninstallLogins are the volume suffixes of the logins and settings that KEEP
// keeps: gh, git identity, Claude Code, opencode and the modules.
var uninstallLogins = []string{"gh", "git", "claude", "opencode-config", "opencode-data", "config"}

// uninstallKeep returns the KEEP value: KEEP, else GARDER (the French name).
// "" removes everything; "logins" (or "connexions") keeps the logins volumes.
// Any other value is refused, as the shell uninstaller did.
func uninstallKeep() (string, error) {
	keep := os.Getenv("KEEP")
	if keep == "" {
		keep = os.Getenv("GARDER")
	}
	switch keep {
	case "", "logins", "connexions":
		return keep, nil
	}
	return "", fmt.Errorf("KEEP: unknown value: %s (only value: logins)", keep)
}

// keepsLogins reports whether a volume of the instance is one KEEP keeps: its
// name ends with one of the logins suffixes.
func keepsLogins(keep, volume string) bool {
	if keep != "logins" && keep != "connexions" {
		return false
	}
	for _, c := range uninstallLogins {
		if strings.HasSuffix(volume, "-"+c) {
			return true
		}
	}
	return false
}

// confirmedByEnv reports whether CONFIRM (else CONFIRMER, the French name) is
// "yes": the confirmation is given without a terminal, as in CI.
func confirmedByEnv() bool {
	v := os.Getenv("CONFIRM")
	if v == "" {
		v = os.Getenv("CONFIRMER")
	}
	return v == "yes"
}

// parseUninstallArgs reads the options of uninstall: only --yes. It returns the
// message to print for an unknown option, "" when the arguments are valid.
func parseUninstallArgs(args []string) (yes bool, bad string) {
	for _, a := range args {
		if a == "--yes" {
			yes = true
			continue
		}
		return false, fmt.Sprintf("✖ unknown option: %s (devzone uninstall [--yes])", a)
	}
	return yes, ""
}
