package main

import (
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/podcmd"
)

// Command devzone-pod is the Go binary of the pod CLI: commands already ported run in Go, the others are delegated to the shell entry point of the pod.
func main() {
	os.Exit(podcmd.Run(os.Args[1:], os.Stdout, os.Stderr))
}
