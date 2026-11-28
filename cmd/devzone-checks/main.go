package main

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/checks"
)

// usage prints the command syntax and exits with the usage code.
func usage() {
	fmt.Fprintln(os.Stderr, "usage: devzone-checks english|layout|names")
	os.Exit(2)
}

// fail prints an error and exits with the failure code.
func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// runEnglish reports the offending words of the tracked code files from root.
func runEnglish(root string) int {
	report, err := checks.CheckEnglish(root)
	if err != nil {
		fail(err)
	}
	for _, fault := range report.Faults {
		fmt.Println(fault.String())
	}
	if len(report.Faults) > 0 {
		return 1
	}
	fmt.Printf("english check: %d files ok\n", report.Files)
	return 0
}

// main runs one repository check from the git root.
func main() {
	if len(os.Args) != 2 {
		usage()
	}
	root, err := checks.RepoRoot()
	if err != nil {
		fail(err)
	}
	var code int
	switch os.Args[1] {
	case "english":
		code = runEnglish(root)
	case "layout":
		code = checks.RunLayout(root, os.Stdout, os.Stderr)
	case "names":
		code = checks.RunNames(root, os.Stdout, os.Stderr)
	default:
		usage()
	}
	os.Exit(code)
}
