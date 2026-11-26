package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTrimJournalKeepsOnlyATail bounds the journal of a watcher that cannot
// reach the cluster, while keeping the last message. It uses only the file
// system, so it stays valid on every platform.
func TestTrimJournalKeepsOnlyATail(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "journal.log")
	writeFile(t, path, strings.Repeat("x", maxJournalBytes+200)+"tail\n")
	trimJournal(dir)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > maxJournalBytes/2+len("tail\n") || !strings.HasSuffix(string(data), "tail\n") {
		t.Fatalf("journal size = %d, suffix = %q", len(data), string(data[len(data)-8:]))
	}
}
