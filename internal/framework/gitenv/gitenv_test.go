package gitenv

import (
	"reflect"
	"testing"
)

// TestCleanRemovesRepositoryVariables checks that only variables which select
// a repository are dropped from a child environment.
func TestCleanRemovesRepositoryVariables(t *testing.T) {
	in := []string{
		"PATH=/bin",
		"GIT_DIR=/other/.git",
		"GIT_WORK_TREE=/other",
		"GIT_INDEX_FILE=/other/.git/index",
		"GIT_COMMON_DIR=/other/.git",
		"GIT_OBJECT_DIRECTORY=/other/.git/objects",
		"GIT_ALTERNATE_OBJECT_DIRECTORIES=/elsewhere",
		"GIT_NAMESPACE=other",
		"GIT_PREFIX=sub",
		"GIT_QUARANTINE_PATH=/other/incoming",
		"GIT_CONFIG_GLOBAL=/home/config",
		"GIT_CONFIG_PARAMETERS=core.hooksPath=/dev/null",
	}
	want := []string{
		"PATH=/bin",
		"GIT_CONFIG_GLOBAL=/home/config",
		"GIT_CONFIG_PARAMETERS=core.hooksPath=/dev/null",
	}
	if got := Clean(in); !reflect.DeepEqual(got, want) {
		t.Fatalf("Clean = %v, want %v", got, want)
	}
}
