// Command devzone is the entry point of the Go binary. It hands the command
// line to internal/command: the commands already ported run in Go, the others
// are delegated to the bash entry point (strangler migration, #358).
package main

import (
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/command"
)

func main() {
	os.Exit(command.Run(os.Args[1:], os.Stdout, os.Stderr))
}
