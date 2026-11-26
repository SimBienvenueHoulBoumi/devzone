package catalog

import (
	"os"
	"strings"
	"testing"
)

// readLog returns the whole content of a test log file.
func readLog(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}
