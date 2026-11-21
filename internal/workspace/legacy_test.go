package workspace

import "testing"

func TestLegacyMessageOneFolder(t *testing.T) {
	want := "⚠ legacy copies in the pod (their .git points outside the pod): /workspaces/projets/wt\n" +
		"  1. save what you need: devzone workspace copy-from <folder>\n" +
		"  2. remove them from the pod shell (devzone workspace shell), one folder at a time:\n" +
		"       rm -rf /workspaces/projets/wt\n"
	if got := legacyMessage([]string{"wt"}); got != want {
		t.Fatalf("legacyMessage =\n%q\nwant\n%q", got, want)
	}
}

func TestLegacyMessageTwoFolders(t *testing.T) {
	want := "⚠ legacy copies in the pod (their .git points outside the pod): /workspaces/projets/repogarde /workspaces/projets/wt\n" +
		"  1. save what you need: devzone workspace copy-from <folder>\n" +
		"  2. remove them from the pod shell (devzone workspace shell), one folder at a time:\n" +
		"       rm -rf /workspaces/projets/repogarde\n" +
		"       rm -rf /workspaces/projets/wt\n"
	if got := legacyMessage([]string{"repogarde", "wt"}); got != want {
		t.Fatalf("legacyMessage =\n%q\nwant\n%q", got, want)
	}
}
