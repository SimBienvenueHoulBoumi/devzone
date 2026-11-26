package argocd

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// Options carries the collaborators and the paths of an argocd command run.
type Options struct {
	Runner          exec.Runner
	Launcher        relay.Launcher
	Out             io.Writer
	Err             io.Writer
	Root            string
	CodeRoot        string
	StatePath       string
	KubeHost        string
	KubeConfig      string
	Workspace       string
	GitHubToken     string
	GitHubAuth      bool
	GitHubUser      string
	GitHubTokenFunc func() (string, error)
}
