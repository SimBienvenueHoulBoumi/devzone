// Package clustermenu is the way out of "no cluster" at creation (#653): the Go
// port of manage/scripts/create-cluster.sh (#884). A menu offers a remote
// cluster (a context of the kubeconfig, its name typed back to confirm, #326) or
// a local minikube cluster (profile devzone). It never runs a cloud command and
// never installs minikube: it only displays the official command.
package clustermenu

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Menu holds the inputs and outputs of one run of the menu. In is read for every
// answer, so all the prompts of a run share one buffered reader.
type Menu struct {
	Ctx      context.Context
	Runner   exec.Runner
	LookPath func(file string) (string, error)
	GOOS     string
	In       *bufio.Reader
	Out      io.Writer
	Err      io.Writer
}

// Offer shows the choice and runs the one picked. It returns true when a cluster
// was selected or created (the caller checks that it answers), false otherwise.
func (m *Menu) Offer() bool {
	fmt.Fprintln(m.Out, "No Kubernetes cluster answers. Pick one:")
	fmt.Fprintln(m.Out, "  1) a remote cluster (AWS, GCP, Azure, other: a context of your kubeconfig)")
	fmt.Fprintln(m.Out, "  2) a local minikube cluster (profile devzone)")
	switch m.ask("Your choice (empty to cancel): ") {
	case "1":
		return m.remote()
	case "2":
		return m.minikube()
	}
	fmt.Fprintln(m.Err, "✖ cancelled")
	return false
}

// ask prints prompt, then reads one answer and trims the blanks around it, as
// "read -r" does. A line cut by the end of the input is an empty answer, as in
// the shell, where read fails on it.
func (m *Menu) ask(prompt string) string {
	fmt.Fprint(m.Out, prompt)
	line, err := m.In.ReadString('\n')
	if err != nil {
		return ""
	}
	return strings.TrimSpace(line)
}

// run calls a command through the Runner. It returns false when the command
// could not start or exited non-zero; the captured output is then ignored.
func (m *Menu) run(name string, args ...string) (exec.Result, bool) {
	res, err := m.Runner.Run(m.Ctx, name, args, exec.Opts{})
	return res, err == nil && res.Code == 0
}
