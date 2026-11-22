package agent

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// agentErrorsScript returns the path to .devcontainer/agent-errors.sh
// starting from the test directory (internal/agent), going up two levels.
func agentErrorsScript(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(wd, "..", "..", ".devcontainer", "agent-errors.sh")
	if _, err := os.Stat(script); err != nil {
		t.Fatal("cannot find agent-errors.sh:", err)
	}
	return script
}

// runErrors runs a bash command sourcing the agent-errors.sh script and returns stdout.
func runErrors(t *testing.T, body, log string) string {
	t.Helper()
	script := agentErrorsScript(t)
	cmd := exec.Command("bash", "-c", `. "$1"; `+body, "_", script, log)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("cannot run bash: %v", err)
	}
	return strings.TrimRight(string(out), "\n")
}

// journal joins lines with newlines (no trailing newline).
func journal(lines ...string) string {
	return strings.Join(lines, "\n")
}

// TestErrorLinesTitleOnly tests title-only error (Free usage limit reached)
func TestErrorLinesTitleOnly(t *testing.T) {
	t.Parallel()
	log := journal(
		`timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title Free usage limit reached`,
	)
	result := runErrors(t, `error_cause "$(error_lines "$2")"`, log)
	if result != "autre" {
		t.Errorf("expected 'autre', got %q", result)
	}
}

// TestErrorLinesTitleOnlyCountry tests title-only error (not available in your country)
func TestErrorLinesTitleOnlyCountry(t *testing.T) {
	t.Parallel()
	log := journal(
		`timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title not available in your country`,
	)
	result := runErrors(t, `error_cause "$(error_lines "$2")"`, log)
	if result != "autre" {
		t.Errorf("expected 'autre', got %q", result)
	}
}

// TestErrorLinesBuildAndTitle tests title (quota) + build (Upstream request failed)
func TestErrorLinesBuildAndTitle(t *testing.T) {
	t.Parallel()
	log := journal(
		`timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title Free usage limit reached`,
		`timestamp=2024-01-01T00:01:00Z level=ERROR small=false agent=build Upstream request failed`,
	)
	result := runErrors(t, `error_cause "$(error_lines "$2")"`, log)
	if result != "autre" {
		t.Errorf("expected 'autre', got %q", result)
	}
}

// TestErrorLinesBuildAndTitleQuota tests build (quota) + title (Upstream request failed)
func TestErrorLinesBuildAndTitleQuota(t *testing.T) {
	t.Parallel()
	log := journal(
		`timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title Upstream request failed`,
		`timestamp=2024-01-01T00:01:00Z level=ERROR small=false agent=build Free usage limit reached`,
	)
	result := runErrors(t, `error_cause "$(error_lines "$2")"`, log)
	if result != "quota" {
		t.Errorf("expected 'quota', got %q", result)
	}

	// Verify that error_lines doesn't contain agent=title
	lines := runErrors(t, `error_lines "$2"`, log)
	if strings.Contains(lines, "agent=title") {
		t.Error("error_lines should not contain agent=title")
	}
}

// TestErrorLinesPlanExploreTitle tests plan (quota) + explore (Upstream request failed) + title (Upstream request failed)
func TestErrorLinesPlanExploreTitle(t *testing.T) {
	t.Parallel()
	log := journal(
		`timestamp=2024-01-01T00:00:00Z level=ERROR small=false agent=plan Free usage limit reached`,
		`timestamp=2024-01-01T00:01:00Z level=ERROR small=false agent=explore Upstream request failed`,
		`timestamp=2024-01-01T00:02:00Z level=ERROR small=true agent=title Upstream request failed`,
	)
	lines := runErrors(t, `error_lines "$2"`, log)
	if !strings.Contains(lines, "agent=plan") {
		t.Error("error_lines should contain agent=plan")
	}
	if !strings.Contains(lines, "agent=explore") {
		t.Error("error_lines should contain agent=explore")
	}
	if strings.Contains(lines, "agent=title") {
		t.Error("error_lines should not contain agent=title")
	}

	result := runErrors(t, `error_cause "$(error_lines "$2")"`, log)
	if result != "quota" {
		t.Errorf("expected 'quota', got %q", result)
	}
}
