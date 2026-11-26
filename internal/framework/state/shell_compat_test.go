package state

import (
	"os"
	"path/filepath"
	"testing"
)

// TestShellWriteRemoveReplaceGoEquivalent checks frozen results of writing,
// removing, replacing, copying and filtering the state file: return code,
// output (none), resulting state and .prev backup, taken from the shell
// comparison before state.sh was removed.
func TestShellWriteRemoveReplaceGoEquivalent(t *testing.T) {
	type operation struct {
		name      string
		initial   string
		wantState string
		wantPrev  string
		hasPrev   bool
		apply     func(s *State) error
	}
	ops := []operation{
		{name: "write missing state", wantState: "ai=on\n",
			apply: func(s *State) error { return s.Set("ai", "on") }},
		{name: "write replaces only its key", initial: "unknown line\nai=off\nkubernetes=off\n",
			wantState: "unknown line\nkubernetes=off\nai=on\n", wantPrev: "unknown line\nai=off\nkubernetes=off\n", hasPrev: true,
			apply: func(s *State) error { return s.Set("ai", "on") }},
		{name: "remove existing key", initial: "ai=on\nkubernetes=off\n",
			wantState: "kubernetes=off\n", wantPrev: "ai=on\nkubernetes=off\n", hasPrev: true,
			apply: func(s *State) error { return s.Delete("ai") }},
		{name: "remove absent key", initial: "ai=on\n",
			wantState: "ai=on\n", wantPrev: "ai=on\n", hasPrev: true,
			apply: func(s *State) error { return s.Delete("mysql") }},
		{name: "remove without state", wantState: "",
			apply: func(s *State) error { return s.Delete("ai") }},
	}
	for _, op := range ops {
		t.Run(op.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "go.modules")
			if op.initial != "" {
				writeStateFile(t, path, op.initial)
			}
			if err := op.apply(At(path)); err != nil {
				t.Fatalf("code 1, want frozen code 0: %v", err)
			}
			assertFile(t, path, op.wantState)
			assertPrev(t, path+".prev", op.hasPrev, op.wantPrev)
		})
	}
}

// TestShellBackupReplaceFilterGoEquivalent checks frozen whole-file results:
// replace (state + .prev), backup (.prev) and filter (output file), with the
// frozen code taken from the shell comparison before state.sh was removed.
func TestShellBackupReplaceFilterGoEquivalent(t *testing.T) {
	dir := t.TempDir()
	initial := "ai=off\nkubernetes=on\n"

	source := filepath.Join(dir, "source")
	writeStateFile(t, source, "cluster=kind-devzone\nai=on\n")
	replacePath := filepath.Join(dir, "replace.modules")
	writeStateFile(t, replacePath, initial)
	if err := At(replacePath).Replace(source); err != nil {
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	assertFile(t, replacePath, "cluster=kind-devzone\nai=on\n")
	assertPrev(t, replacePath+".prev", true, initial)

	backupPath := filepath.Join(dir, "backup.modules")
	writeStateFile(t, backupPath, initial)
	if err := At(backupPath).backupLocked(); err != nil {
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	assertFile(t, backupPath, initial)
	assertPrev(t, backupPath+".prev", true, initial)

	content := "ai=on\nunknown\nai=off\nkubernetes=off\n"
	filterPath := filepath.Join(dir, "filter.modules")
	writeStateFile(t, filterPath, content)
	lines, err := At(filterPath).filteredLines("ai")
	if err != nil {
		t.Fatal(err)
	}
	if got := joinLines(lines); got != "unknown\nkubernetes=off\n" {
		t.Fatalf("filter output %q, want %q", got, "unknown\nkubernetes=off\n")
	}
}

// writeStateFile writes a state or source file in a disposable folder.
func writeStateFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// assertFile checks exact file content.
func assertFile(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		got = nil
		err = nil
	}
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("%s = %q, want %q", path, got, want)
	}
}

// assertPrev checks the .prev backup presence and exact content.
func assertPrev(t *testing.T, path string, present bool, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if !present {
		if !os.IsNotExist(err) {
			t.Fatalf("%s should be absent, got %q (%v)", path, got, err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("%s = %q, want %q", path, got, want)
	}
}

// joinLines renders filtered lines like state_filter output.
func joinLines(lines []string) string {
	out := ""
	for _, line := range lines {
		out += line + "\n"
	}
	return out
}
