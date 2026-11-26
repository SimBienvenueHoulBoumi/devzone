package main

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/checks"
)

// main runs the English check of the tracked code files from the git root.
func main() {
	if len(os.Args) != 2 || os.Args[1] != "english" {
		fmt.Fprintln(os.Stderr, "usage: devzone-checks english")
		os.Exit(2)
	}
	root, err := checks.RepoRoot()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	report, err := checks.CheckEnglish(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, fault := range report.Faults {
		fmt.Println(fault.String())
	}
	if len(report.Faults) > 0 {
		os.Exit(1)
	}
	fmt.Printf("english check: %d files ok\n", report.Files)
}
