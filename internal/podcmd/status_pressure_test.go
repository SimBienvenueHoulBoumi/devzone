package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pressureFiles writes fake cgroup files under a temporary root and returns the
// root and the baseline path; an empty value leaves the file out.
func pressureFiles(t *testing.T, pidsCurrent, pidsMax, memoryEvents string) (root, baseline string) {
	t.Helper()
	root = t.TempDir()
	baseline = filepath.Join(t.TempDir(), "count")
	files := map[string]string{"pids.current": pidsCurrent, "pids.max": pidsMax, "memory.events": memoryEvents}
	for name, content := range files {
		if content == "" {
			continue
		}
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root, baseline
}

// TestPressurePidsThreshold checks that the pids warning starts above 70 % of
// pids.max and not at or below it, and that a "max" limit is never compared.
func TestPressurePidsThreshold(t *testing.T) {
	cases := []struct {
		name, current, max string
		warn               bool
	}{
		{"at 70 percent", "7000", "10000", false},
		{"above 70 percent", "7001", "10000", true},
		{"far below", "120", "24006", false},
		{"no limit", "99999", "max", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root, baseline := pressureFiles(t, c.current, c.max, "")
			got := pressureWarning(root, baseline)
			if (got != "") != c.warn {
				t.Fatalf("warning = %q, want warning %v", got, c.warn)
			}
			if c.warn && !strings.Contains(got, c.current+" of "+c.max+" processes") {
				t.Fatalf("warning %q does not give the counts", got)
			}
		})
	}
}

// TestPressureMemoryEventsRise checks that the first call only records the
// counter, that a rise of at least memoryMaxJump warns, and that a smaller rise
// or a counter reset (container restart) does not.
func TestPressureMemoryEventsRise(t *testing.T) {
	events := func(n string) string {
		return "low 0\nhigh 0\nmax " + n + "\noom 0\noom_kill 0\n"
	}
	root, baseline := pressureFiles(t, "", "", events("10"))
	if got := pressureWarning(root, baseline); got != "" {
		t.Fatalf("first call warned: %q", got)
	}
	writeFile(t, filepath.Join(root, "memory.events"), events("10"))
	if got := pressureWarning(root, baseline); got != "" {
		t.Fatalf("no rise, warned: %q", got)
	}
	writeFile(t, filepath.Join(root, "memory.events"), events("30"))
	if got := pressureWarning(root, baseline); got != "" {
		t.Fatalf("rise of 20 warned: %q", got)
	}
	writeFile(t, filepath.Join(root, "memory.events"), events("120"))
	got := pressureWarning(root, baseline)
	if !strings.Contains(got, "memory limit hit 90 times") || !strings.Contains(got, "resources.limits.memory") {
		t.Fatalf("rise of 90 not reported: %q", got)
	}
	writeFile(t, filepath.Join(root, "memory.events"), events("2"))
	if got := pressureWarning(root, baseline); got != "" {
		t.Fatalf("counter reset warned: %q", got)
	}
}

// TestPressureMissingFiles checks that nothing is printed and no baseline is
// written where the cgroup files do not exist, as on a workstation.
func TestPressureMissingFiles(t *testing.T) {
	root, baseline := pressureFiles(t, "", "", "")
	if got := pressureWarning(root, baseline); got != "" {
		t.Fatalf("warning without cgroup files: %q", got)
	}
	if _, err := os.Stat(baseline); err == nil {
		t.Fatal("baseline written without memory.events")
	}
}

// TestPressureBothWarnings checks that both conditions appear in the one line.
func TestPressureBothWarnings(t *testing.T) {
	root, baseline := pressureFiles(t, "9000", "10000", "max 60\n")
	writeFile(t, baseline, "0\n")
	got := pressureWarning(root, baseline)
	contains(t, got, "9000 of 10000 processes", "memory limit hit 60 times")
	if strings.Contains(got, "\n") {
		t.Fatalf("warning spans several lines: %q", got)
	}
}

// writeFile replaces a file of a test fixture, failing the test on error.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
