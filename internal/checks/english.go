package checks

import (
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/gitenv"
)

// Patterns of the English check, kept as data so the source never holds the
// French words it looks for. Both files are excluded from the check as data.
//
//go:embed english_words.txt french_commands.txt
var patterns embed.FS

// Fault is one offending line of a tracked code file.
type Fault struct {
	Path string
	Line int
	Text string
	Rule string
	Word string
}

// Report is the result of the English check.
type Report struct {
	Files  int
	Faults []Fault
}

// frequentWords reads the frequent French words from the embedded data file.
func frequentWords() []string {
	data, err := patterns.ReadFile("english_words.txt")
	if err != nil {
		panic(err)
	}
	return dataLines(string(data))
}

// commandWords reads the French command words from the embedded data file.
func commandWords() []string {
	data, err := patterns.ReadFile("french_commands.txt")
	if err != nil {
		panic(err)
	}
	return dataLines(string(data))
}

// dataLines keeps the non-empty, non-comment lines of a data file.
func dataLines(data string) []string {
	var out []string
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}

// frequentPattern is the whole-word matcher built from the data file.
var frequentPattern = func() *regexp.Regexp {
	parts := make([]string, 0, len(frequentWords()))
	for _, word := range frequentWords() {
		parts = append(parts, regexp.QuoteMeta(word))
	}
	return regexp.MustCompile(`(?i)\b(?:` + strings.Join(parts, "|") + `)\b`)
}()

// commandSet holds the French command words using the exact spelling of a token.
var commandSet = func() map[string]bool {
	set := make(map[string]bool)
	for _, word := range commandWords() {
		set[word] = true
	}
	return set
}()

// RepoRoot returns the top level of the git working tree of the current folder.
func RepoRoot() (string, error) {
	cmd := exec.Command("git", "rev-parse", "--show-toplevel")
	cmd.Env = gitenv.Clean(os.Environ())
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git rev-parse: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// trackedFiles lists the files tracked by git; a git error is never an empty list.
func trackedFiles(root string) ([]string, error) {
	cmd := exec.Command("git", "ls-files", "--cached")
	cmd.Dir = root
	cmd.Env = gitenv.Clean(os.Environ())
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files in %s: %w", root, err)
	}
	var files []string
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" {
			files = append(files, line)
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("git ls-files in %s: no tracked file", root)
	}
	return files, nil
}

// isCodeFile accepts the extensions of the files once listed in .english, plus
// the extensionless code files; data and documentation are excluded by path.
func isCodeFile(path string) bool {
	// Issue forms and the detector's word list hold French words as data.
	if strings.HasPrefix(path, ".github/ISSUE_TEMPLATE/") || path == "manage/test/cli-english.bats" {
		return false
	}
	ext := strings.TrimPrefix(filepath.Ext(path), ".")
	switch ext {
	case "go", "sh", "bats", "bash", "yaml", "yml", "js", "tpl", "messages":
		return true
	case "":
		return true
	default:
		return false
	}
}

// CheckEnglish checks every tracked code file under root.
func CheckEnglish(root string) (Report, error) {
	return checkEnglish(root, trackedFiles)
}

// checkEnglish is the testable core: the file list is injected by the caller.
func checkEnglish(root string, list func(string) ([]string, error)) (Report, error) {
	files, err := list(root)
	if err != nil {
		return Report{}, err
	}
	if len(files) == 0 {
		return Report{}, fmt.Errorf("no file to check in %s", root)
	}
	report := Report{}
	for _, path := range files {
		if !isCodeFile(path) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			return Report{}, fmt.Errorf("read %s: %w", path, err)
		}
		report.Files++
		scanLines(&report, path, string(data))
	}
	return report, nil
}

// scanLines appends the faults of one file, scanning whole lines including comments.
func scanLines(report *Report, path, data string) {
	scanner := &lineScanner{}
	for number, line := range strings.Split(data, "\n") {
		if hasFrenchWord(line) {
			report.Faults = append(report.Faults, Fault{Path: path, Line: number + 1, Text: line, Rule: "english"})
		}
		for _, token := range scanner.frenchTokens(line) {
			report.Faults = append(report.Faults, Fault{Path: path, Line: number + 1, Text: line, Rule: "command", Word: token})
		}
	}
}

// String renders a fault as path:line: text, as the former shell check did.
func (f Fault) String() string {
	return fmt.Sprintf("%s:%d: %s", f.Path, f.Line, f.Text)
}
