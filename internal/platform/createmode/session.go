// Package createmode holds the Go port of the workspace-mode decision made at
// creation (#884): the cluster check, the mode file and the start of the new
// folder. Every external command goes through a Runner, so tests stay hermetic.
package createmode

import (
	"bytes"
	"context"
	"io"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// Session carries the inputs and outputs of one creation decision. Terminal
// says whether the caller may offer the cluster menu to the user.
type Session struct {
	Ctx      context.Context
	Runner   fexec.Runner
	LookPath func(string) (string, error)
	GOOS     string
	In       io.Reader
	Out      io.Writer
	Err      io.Writer
	Terminal bool
}

// ctx returns the context of the session, or the background one when unset.
func (s *Session) ctx() context.Context {
	if s.Ctx == nil {
		return context.Background()
	}
	return s.Ctx
}

// runner returns the injected runner, or the process one when unset.
func (s *Session) runner() fexec.Runner {
	if s.Runner == nil {
		return fexec.ExecRunner{}
	}
	return s.Runner
}

// run calls one program through the runner and reports whether it succeeded.
func (s *Session) run(name string, args ...string) (fexec.Result, bool) {
	res, err := s.runner().Run(s.ctx(), name, args, fexec.Opts{})
	return res, err == nil && res.Code == 0
}

// ready checks the cluster with the same rules as the workspace start path.
func (s *Session) ready() (string, bool) {
	return workspace.KubeReadyWith(kubeAdapter{s.runner()}, s.LookPath, false)
}

// kubeAdapter presents the command runner as the kubectl and helm runner used
// by the cluster check, so a test can program those calls.
type kubeAdapter struct {
	runner fexec.Runner
}

// Kubectl runs kubectl through the command runner and copies its output back.
func (k kubeAdapter) Kubectl(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return k.run("kubectl", args, stdin, stdout, stderr)
}

// Helm runs helm through the command runner and copies its output back.
func (k kubeAdapter) Helm(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return k.run("helm", args, stdin, stdout, stderr)
}

// run carries one command and its streams through the injected runner.
func (k kubeAdapter) run(name string, args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	res, err := k.runner.Run(context.Background(), name, args, fexec.Opts{Stdin: stdin})
	_, _ = io.Copy(stdout, bytes.NewReader(res.Stdout))
	_, _ = io.Copy(stderr, bytes.NewReader(res.Stderr))
	return res.Code, err
}

// ContextName returns the shared services context when kubeconfig declares it,
// otherwise the current context, or none when kubectl cannot name one.
func (s *Session) ContextName() string {
	wanted := fexec.ContextName()
	if res, ok := s.run("kubectl", "config", "get-contexts", "-o", "name"); ok && hasContext(res.Stdout, wanted) {
		return wanted
	}
	if res, ok := s.run("kubectl", "config", "current-context"); ok {
		if value := strings.TrimSpace(string(res.Stdout)); value != "" {
			return value
		}
	}
	return "none"
}

// hasContext tells whether one exact context name appears in the kubectl list.
func hasContext(out []byte, name string) bool {
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == name {
			return true
		}
	}
	return false
}
