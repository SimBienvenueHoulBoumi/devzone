package checks

import (
	"embed"
	"fmt"
	"io"
	"strings"
)

//go:embed french_name_words.txt
var nameWords embed.FS

// userDataNames are the user data paths kept under their existing names.
var userDataNames = []string{".devzone.modules", ".devzone.version"}

// NameReport is the result of the path name check.
type NameReport struct {
	Paths  int
	Faults []string
}

// frenchNameWords reads the fragmented name words from the embedded data file,
// so the source never holds the words that the rule rejects.
func frenchNameWords() map[string]bool {
	data, err := nameWords.ReadFile("french_name_words.txt")
	if err != nil {
		panic(err)
	}
	set := make(map[string]bool)
	for _, line := range dataLines(string(data)) {
		for _, word := range strings.Fields(strings.ReplaceAll(line, "_", "")) {
			set[word] = true
		}
	}
	return set
}

// pathWords splits a path on the separators used by the shell check.
func pathWords(path string) []string {
	return strings.FieldsFunc(path, func(r rune) bool {
		return r == '/' || r == '.' || r == '_' || r == '-'
	})
}

// isUserData reports whether a path is an allowed user data path or is below
// one of them.
func isUserData(path string) bool {
	for _, name := range userDataNames {
		if path == name || strings.HasPrefix(path, name+"/") {
			return true
		}
	}
	return false
}

// CheckNames checks every listed path under root against the name rules.
func CheckNames(root string) (NameReport, error) {
	paths, err := listedPaths(root)
	if err != nil {
		return NameReport{}, err
	}
	forbidden := frenchNameWords()
	report := NameReport{}
	for _, path := range paths {
		if strings.HasPrefix(path, ".github/") {
			continue
		}
		report.Paths++
		for _, word := range pathWords(path) {
			if !forbidden[word] || isUserData(path) {
				continue
			}
			report.Faults = append(report.Faults, fmt.Sprintf("%s: %s", path, word))
		}
	}
	return report, nil
}

// RunNames prints the name check report and returns the check's exit code.
func RunNames(root string, out, errOut io.Writer) int {
	report, err := CheckNames(root)
	if err != nil {
		reportGitFailure(errOut, err, "check-names", root)
		return 1
	}
	for _, fault := range report.Faults {
		fmt.Fprintln(out, fault)
	}
	if len(report.Faults) > 0 {
		return 1
	}
	fmt.Fprintf(out, "names check: %d paths ok\n", report.Paths)
	return 0
}
