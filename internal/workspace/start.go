package workspace

import (
	"fmt"
	"io"
	"strings"
)

// ArgoCDWanted tells whether the workstation wants Argo CD, as argocd_wanted in
// argocd-workspace.sh: only the exact line argocd=off turns it off.
func ArgoCDWanted(modules string) bool {
	return argocdWanted(modules)
}

// ArgoCDInstalled reports whether the Argo CD namespace exists in the cluster.
func ArgoCDInstalled(r Runner) bool {
	return argocdInstalled(r)
}

// StartEnv runs the helm-direct form of "workspace start". The forms that need
// Argo CD or its GitOps repository are delegated by the caller until those
// libraries are ported. Every external action is injected, so no test starts
// a watcher or reaches a cluster.
type StartEnv struct {
	Runner     Runner
	Modules    string
	Root       string
	Out        io.Writer
	ErrOut     io.Writer
	Ready      func() (string, bool)
	Deploy     func(repository, tag string, withImage bool) int
	Reconcile  func() int
	Wait       func(image string) int
	Guard      func()
	PortsStart func()
}

// Run parses --image, deploys the chart, waits for the pod, installs the guard
// of the agents and starts the port watcher, as start_workspace does. The
// automatic start of the watcher is added by the command layer afterwards.
func (e StartEnv) Run(args []string) int {
	repository, tag, withImage, ok := e.options(args)
	if !ok {
		return 1
	}
	if reason, ready := e.ready(); !ready {
		fmt.Fprintln(e.ErrOut, reason)
		return 1
	}
	image := repository + ":" + tag
	if status := e.deploy(repository, tag, withImage); status != 0 {
		return status
	}
	if status := e.wait(image); status != 0 {
		return status
	}
	e.guard()
	e.startPorts()
	return 0
}

// options reads the only option of start, --image <repository:tag>.
func (e StartEnv) options(args []string) (repository, tag string, withImage, ok bool) {
	repository, tag = imageRepo, "latest"
	if root := e.root(); root != "" {
		if version := DefaultImageTag(root); version != "latest" {
			tag = version
		}
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--image":
			if i+1 >= len(args) || args[i+1] == "" {
				fmt.Fprintln(e.ErrOut, "✖ option --image: provide an image <repository:tag> (devzone workspace start --image <repository:tag>)")
				return "", "", false, false
			}
			i++
			value := args[i]
			if !strings.Contains(value, ":") {
				fmt.Fprintln(e.ErrOut, "✖ option --image: image has no tag, expected <repository:tag> (devzone workspace start --image <repository:tag>)")
				return "", "", false, false
			}
			parts := strings.Split(value, ":")
			repository = strings.Join(parts[:len(parts)-1], ":")
			tag = parts[len(parts)-1]
			withImage = true
		default:
			fmt.Fprintf(e.ErrOut, "✖ unknown option: %s (devzone workspace start [--image <repository:tag>])\n", args[i])
			return "", "", false, false
		}
	}
	return repository, tag, withImage, true
}

// root returns the package root explicitly set by the caller, or the one found
// from the binary.
func (e StartEnv) root() string {
	if e.Root != "" {
		return e.Root
	}
	return packageRoot()
}

func (e StartEnv) ready() (string, bool) {
	if e.Ready != nil {
		return e.Ready()
	}
	return KubeReady(e.Runner, true)
}

func (e StartEnv) deploy(repository, tag string, withImage bool) int {
	if e.Deploy != nil {
		return e.Deploy(repository, tag, withImage)
	}
	return HelmDeploy(e.Runner, e.Modules, repository, tag, withImage, e.Out, e.ErrOut)
}

func (e StartEnv) wait(image string) int {
	if e.Wait != nil {
		return e.Wait(image)
	}
	return WaitForPod(e.Runner, image, e.Out, e.ErrOut, func() int {
		return Undeploy(e.Runner, e.Out, e.ErrOut)
	})
}

func (e StartEnv) guard() {
	if e.Guard != nil {
		e.Guard()
		return
	}
	AgentsGuard(e.Runner, e.Out)
}

func (e StartEnv) startPorts() {
	if e.PortsStart != nil {
		e.PortsStart()
		return
	}
	_ = PortsStart(io.Discard, e.ErrOut)
}

// Undeploy removes the helm release of the workspace, as workspace_undeploy
// does when no Argo CD Application holds it.
func Undeploy(r Runner, out, errOut io.Writer) int {
	args := append(helmFlag(r), "uninstall", "devzone-workspace", "--namespace", namespace)
	status, err := r.Helm(args, nil, out, errOut)
	if err != nil {
		return notStarted
	}
	return status
}
