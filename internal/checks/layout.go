package checks

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/gitenv"
)

// maxLines is the single ceiling for the line count of a Go file.
const maxLines = 250

// errGitList marks a failure of the git path listing.
var errGitList = errors.New("git ls-files failed")

// LayoutReport is the result of the Go file line count check.
type LayoutReport struct {
	Files  int
	Faults []string
}

// listedPaths lists the paths git knows under root, plus the new ones that
// are not ignored; args narrows the list to a pathspec when given.
func listedPaths(root string, args ...string) ([]string, error) {
	argv := append([]string{"ls-files", "--cached", "--others", "--exclude-standard", "--"}, args...)
	cmd := exec.Command("git", argv...)
	cmd.Dir = root
	cmd.Env = gitenv.Clean(os.Environ())
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%w in %s: %v", errGitList, root, err)
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" {
			paths = append(paths, line)
		}
	}
	return paths, nil
}

// countLines counts records as awk NR does, including an unterminated last line.
func countLines(data []byte) int {
	if len(data) == 0 {
		return 0
	}
	lines := bytes.Count(data, []byte("\n"))
	if data[len(data)-1] != '\n' {
		lines++
	}
	return lines
}

// CheckLayout counts the lines of every listed Go file that exists on disk.
func CheckLayout(root string) (LayoutReport, error) {
	paths, err := listedPaths(root, "*.go")
	if err != nil {
		return LayoutReport{}, err
	}
	report := LayoutReport{}
	for _, path := range paths {
		full := filepath.Join(root, filepath.FromSlash(path))
		info, err := os.Stat(full)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		data, err := os.ReadFile(full)
		if err != nil {
			return LayoutReport{}, fmt.Errorf("read %s: %w", path, err)
		}
		report.Files++
		lines := countLines(data)
		if lines > maxLines {
			report.Faults = append(report.Faults, fmt.Sprintf("%s: %d lines (max %d)", path, lines, maxLines))
		}
	}
	return report, nil
}

// reportGitFailure writes the shell-compatible message for a failed listing.
func reportGitFailure(errOut io.Writer, err error, label, root string) {
	if errors.Is(err, errGitList) {
		fmt.Fprintf(errOut, "%s: git ls-files fails in %s\n", label, root)
		return
	}
	fmt.Fprintln(errOut, err)
}

// RunLayout prints the line count report and returns the check's exit code.
func RunLayout(root string, out, errOut io.Writer) int {
	report, err := CheckLayout(root)
	if err != nil {
		reportGitFailure(errOut, err, "check-go-layout", root)
		return 1
	}
	for _, fault := range report.Faults {
		fmt.Fprintln(out, fault)
	}
	if len(report.Faults) > 0 {
		return 1
	}
	fmt.Fprintf(out, "go layout: %d files ok\n", report.Files)
	return 0
}
