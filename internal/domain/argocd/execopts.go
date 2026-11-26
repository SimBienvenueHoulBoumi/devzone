package argocd

import (
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// stdinOpt returns exec opts with stdin content.
func stdinOpt(s string) fexec.Opts {
	return fexec.Opts{Stdin: strings.NewReader(s)}
}

// noStdin returns empty exec opts.
func noStdin() fexec.Opts { return fexec.Opts{} }
