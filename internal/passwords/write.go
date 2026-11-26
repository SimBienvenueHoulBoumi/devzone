package passwords

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// sortEntries orders the entries by service, then by user, then by the whole
// line, like LC_ALL=C sort -t tab -k1,1 -k3,3 on the former shell output.
func sortEntries(entries []string) {
	fields := func(line string) [3]string {
		parts := strings.SplitN(line, tabSep, 3)
		var out [3]string
		for i, part := range parts {
			if i < 3 {
				out[i] = part
			}
		}
		return out
	}
	sort.Slice(entries, func(i, j int) bool {
		a, b := fields(entries[i]), fields(entries[j])
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		if a[2] != b[2] {
			return a[2] < b[2]
		}
		return entries[i] < entries[j]
	})
}

// writeAtomic replaces target with data through a temporary file in the same
// folder, with mode 600 set before the rename. A failure leaves the previous
// file untouched and removes the temporary file.
func writeAtomic(target string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(target), ".password.XXXXXX")
	if err != nil {
		return err
	}
	name := tmp.Name()
	done := false
	defer func() {
		_ = tmp.Close()
		if !done {
			_ = os.Remove(name)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, target); err != nil {
		return err
	}
	done = true
	return nil
}
