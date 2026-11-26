package checks

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestHasAccentMatchesExactBytePairs checks the exact byte pairs of the rule.
func TestHasAccentMatchesExactBytePairs(t *testing.T) {
	cases := []struct {
		line string
		want bool
	}{
		{"caf\xc3\xa9", true},
		{"\xc3\x89cole", true},
		{"\xc5\x92uvre", true},
		{"caf\xc3\xa1", false},
		{"plain ascii", false},
	}
	for _, c := range cases {
		if got := hasAccent([]byte(c.line)); got != c.want {
			t.Errorf("hasAccent(%q) = %v, want %v", c.line, got, c.want)
		}
	}
}

// TestHasFrenchWordMatchesWholeLine checks the whole-word and comment rules.
func TestHasFrenchWordMatchesWholeLine(t *testing.T) {
	cases := []struct {
		line string
		want bool
	}{
		{"a line with dans in it", true},
		{"DANS la ligne", true},
		{"# pour le test", true},
		{"a clean line with nothing", false},
		{"the fichiers are here", false},
		{"le dossier was renamed", true},
	}
	for _, c := range cases {
		if got := hasFrenchWord(c.line); got != c.want {
			t.Errorf("hasFrenchWord(%q) = %v, want %v", c.line, got, c.want)
		}
	}
}

// TestShellCasePatternRejectsFrenchForm checks French words in shell case patterns.
func TestShellCasePatternRejectsFrenchForm(t *testing.T) {
	scanner := &lineScanner{}
	lines := []string{
		`case "${1:-}" in`,
		`    start | demarrer) ports_start ;;`,
		`    status | etat) ports_status ;;`,
		`    *) echo unknown ;;`,
		`esac`,
	}
	want := []int{1, 2}
	var got []int
	for i, line := range lines {
		for _, word := range scanner.frenchTokens(line) {
			if word != "demarrer" && word != "etat" {
				t.Errorf("unexpected token %q", word)
			}
			got = append(got, i)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("faulty lines %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("faulty lines %v, want %v", got, want)
		}
	}
}

// TestGoCaseClauseRejectsFrenchForm checks Go case clauses without flagging data.
func TestGoCaseClauseRejectsFrenchForm(t *testing.T) {
	scanner := &lineScanner{}
	if words := scanner.frenchTokens(`	case "host-set":`); len(words) != 0 {
		t.Errorf("English case clause flagged: %v", words)
	}
	words := scanner.frenchTokens(`	case "hote-poser":`)
	if len(words) != 1 || words[0] != "hote-poser" {
		t.Errorf("French case clause not flagged: %v", words)
	}
	if words := scanner.frenchTokens(`	case strings.Contains(prefix, "plateforme"):`); len(words) != 0 {
		t.Errorf("data value in a Go case flagged: %v", words)
	}
}

// TestDevzoneArgumentsRejectsFrenchCommand checks devzone command arguments only.
func TestDevzoneArgumentsRejectsFrenchCommand(t *testing.T) {
	scanner := &lineScanner{}
	cases := []struct {
		line string
		want int
	}{
		{`devzone gitlab hote-poser`, 1},
		{`bash "$RACINE/manage/devzone" workspace ports demarrer`, 1},
		{`devzone gitlab host-set`, 0},
		{`echo "devzone : password not updated"`, 0},
		{`echo "devzone : chemin refuse"`, 0},
		{`@test "devzone activer refuses" {`, 0},
		{`# devzone demarrer is gone`, 0},
	}
	for _, c := range cases {
		if got := len(scanner.frenchTokens(c.line)); got != c.want {
			t.Errorf("frenchTokens(%q) = %d, want %d", c.line, got, c.want)
		}
	}
}

// TestCheckEnglishScopesFilesAndReportsFaults checks file selection and faults.
func TestCheckEnglishScopesFilesAndReportsFaults(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"manage/scripts/tool.sh":            "#!/bin/bash\n# Pour le test\ndevzone gitlab hote-poser\n",
		"internal/checks/data.txt":          "les des une",
		"manage/docs/page.md":               "# dossier\n",
		"internal/checks/tool.go":           "package checks\n// clean\n",
		".github/ISSUE_TEMPLATE/ticket.yml": "labels: [data]\n",
	}
	for path, content := range files {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	list := []string{"manage/scripts/tool.sh", "internal/checks/data.txt", "manage/docs/page.md", "internal/checks/tool.go", ".github/ISSUE_TEMPLATE/ticket.yml"}
	report, err := checkEnglish(root, func(string) ([]string, error) { return list, nil })
	if err != nil {
		t.Fatal(err)
	}
	if report.Files != 2 {
		t.Errorf("checked %d files, want 2", report.Files)
	}
	if len(report.Faults) != 2 {
		t.Fatalf("got %d faults, want 2: %v", len(report.Faults), report.Faults)
	}
	if report.Faults[0].Rule != "english" || report.Faults[0].Line != 2 {
		t.Errorf("first fault: %+v", report.Faults[0])
	}
	if report.Faults[1].Rule != "command" || report.Faults[1].Word != "hote-poser" {
		t.Errorf("second fault: %+v", report.Faults[1])
	}
	if !strings.Contains(report.Faults[0].String(), "manage/scripts/tool.sh:2: ") {
		t.Errorf("fault text: %q", report.Faults[0].String())
	}
}

// TestCheckEnglishRefusesGitFailureAndEmptyList checks that git errors fail the run.
func TestCheckEnglishRefusesGitFailureAndEmptyList(t *testing.T) {
	root := t.TempDir()
	for _, list := range []func(string) ([]string, error){
		func(string) ([]string, error) { return nil, errors.New("git failed") },
		func(string) ([]string, error) { return nil, nil },
	} {
		report, err := checkEnglish(root, list)
		if err == nil {
			t.Errorf("expected an error, got %+v", report)
		}
		if report.Files != 0 {
			t.Errorf("report after error has %d files", report.Files)
		}
	}
}
