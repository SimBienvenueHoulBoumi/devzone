// Package hostcheck checks that the container engine of the workstation answers
// before a command that needs it: the Go port of the Docker check of the shell
// scripts (#884). The messages are the ones the shell printed, word for word.
package hostcheck

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Ready reports whether dockerCmd answers "docker info". When it does not, it
// writes to errOut the cause (missing, no permission, stopped) and what to do,
// then asks to run commandName again, and returns false. Nothing raw from
// Docker is shown: the output of "info" is only read to choose the message.
func Ready(ctx context.Context, r exec.Runner, dockerCmd, commandName string, errOut io.Writer) bool {
	res, err := r.Run(ctx, dockerCmd, []string{"info"}, exec.Opts{})
	// A start error means the command is missing (or cannot be run at all)
	if err != nil {
		writeMissing(errOut, commandName)
		return false
	}
	if res.Code == 0 {
		return true
	}
	stderr := string(res.Stderr)
	if strings.Contains(stderr, "permission denied") || strings.Contains(stderr, "Permission denied") {
		writeNoPermission(errOut, commandName)
		return false
	}
	writeStopped(errOut, commandName)
	return false
}

// writeMissing prints the message for a Docker command that is not installed
// (install links for Docker Desktop and Docker Engine)
func writeMissing(w io.Writer, commandName string) {
	fmt.Fprintln(w, "✖ Docker not found: devzone needs it to run its container.")
	fmt.Fprintln(w, "  Install Docker Desktop (macOS, Windows, Linux): https://docs.docker.com/desktop/")
	fmt.Fprintln(w, "  or, on Linux, Docker Engine: https://docs.docker.com/engine/install/")
	fmt.Fprintf(w, "  then run %s again\n", commandName)
}

// writeNoPermission prints the message for a user outside the docker group
func writeNoPermission(w io.Writer, commandName string) {
	fmt.Fprintln(w, "✖ Docker denied access: your account is not in the docker group.")
	fmt.Fprintln(w, "  sudo usermod -aG docker $USER, then open a new session (or newgrp docker),")
	fmt.Fprintf(w, "  then run %s again\n", commandName)
}

// writeStopped prints the message for a Docker that is installed but does not respond
func writeStopped(w io.Writer, commandName string) {
	fmt.Fprintln(w, "✖ Docker is installed but does not respond (stopped?).")
	fmt.Fprintln(w, "  Start Docker Desktop (on Linux without Docker Desktop: sudo systemctl start docker),")
	fmt.Fprintf(w, "  then run %s again\n", commandName)
}
