package workspace

import (
	"os"
	"path/filepath"
)

// maxJournalBytes is the size kept in the journal when it is trimmed. Keeping
// only a tail prevents a watcher that cannot reach the cluster from filling the
// disk with the same warning at every start.
const maxJournalBytes = 1 << 20

// trimJournal keeps the last half of maxJournalBytes of the journal of dir when
// it grew beyond the limit. It rewrites the same file in place: renaming a
// temporary file would leave the watcher's open descriptor on the old inode,
// and an unreachable cluster could fill the disk while the loop keeps running.
// A missing or unreadable journal is left alone.
func trimJournal(dir string) {
	path := filepath.Join(dir, "journal.log")
	info, err := os.Stat(path)
	if err != nil || info.Size() <= maxJournalBytes {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	start := len(data) - maxJournalBytes/2
	if start < 0 {
		start = 0
	}
	_ = os.WriteFile(path, data[start:], 0o644)
}
