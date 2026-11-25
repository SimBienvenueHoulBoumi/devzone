// Package cluster cleans unused images from the nodes of the local services
// cluster. It never touches volumes, databases or images of the workstation.
package cluster

import (
	"io"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Options carries the collaborators and the switches of a clean run.
type Options struct {
	Runner       exec.Runner
	Out          io.Writer
	Err          io.Writer
	DryRun       bool
	Quiet        bool
	Root         string
	PollInterval time.Duration
}

// Report summarises one clean run; Code is the exit status of the command.
type Report struct {
	Context    string
	DryRun     bool
	Code       int
	Skipped    bool
	Nodes      []NodeReport
	FreedBytes int64
}

// NodeReport summarises the work done on one node.
type NodeReport struct {
	Name       string
	FreeBefore float64
	FreeAfter  float64
	FreedBytes int64
	Image      string
	Deleted    []string
	Failed     bool
	Low        bool
}
