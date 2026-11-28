package createmode

import (
	"bufio"
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"io"
	"runtime"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/clustermenu"
)

// Choose selects kubernetes only when the cluster answers, prints the notice
// and returns the mode. Without a cluster nothing is selected and the ways to
// get one are explained; the menu may be offered once when allowed.
func (s *Session) Choose(option string) (string, bool) {
	reason, ready := s.ready()
	if !ready && option == "" && s.Terminal && s.menu() {
		reason, ready = s.ready()
	}
	if !ready {
		s.noCluster(reason)
		return "", false
	}
	context := s.ContextName()
	fmt.Fprintf(s.Out, "✔ Kubernetes ready (%s): workspace in the cluster\n", context)
	s.existing(context)
	return "kubernetes", true
}

// noCluster explains how to get a cluster: commands are only displayed, never
// run, and no credential goes through devzone.
func (s *Session) noCluster(reason string) {
	fmt.Fprintf(s.Err, "✖ Kubernetes not reachable: %s. Nothing created.\n", reason)
	fmt.Fprintln(s.Err, "  devzone runs in a Kubernetes cluster. Pick one, then run the same command again:")
	fmt.Fprintln(s.Err, "  - a remote cluster (AWS, GCP, Azure, other): add its context to your kubeconfig, then select it")
	fmt.Fprintln(s.Err, "      aws eks update-kubeconfig --name <cluster>")
	fmt.Fprintln(s.Err, "      gcloud container clusters get-credentials <cluster>")
	fmt.Fprintln(s.Err, "      az aks get-credentials --name <cluster> --resource-group <group>")
	fmt.Fprintln(s.Err, "      kubectl config use-context <context>")
	fmt.Fprintln(s.Err, "  - a local cluster: minikube")
	fmt.Fprintln(s.Err, "      minikube start -p devzone")
}

// menu offers a remote or local cluster through the shared Go menu. It returns
// true only after a choice was accepted, so the caller rechecks the cluster.
func (s *Session) menu() bool {
	osName := s.GOOS
	if osName == "" {
		osName = runtime.GOOS
	}
	in := s.In
	if in == nil {
		in = emptyInput{}
	}
	menu := &clustermenu.Menu{
		Ctx:      s.ctx(),
		Runner:   s.runner(),
		LookPath: s.LookPath,
		GOOS:     osName,
		In:       bufio.NewReader(in),
		Out:      s.Out,
		Err:      s.Err,
	}
	return menu.Offer()
}

// emptyInput gives an immediate empty answer when the caller supplies no input.
type emptyInput struct{}

// Read ends the input at once, which cancels the menu as an empty answer does.
func (emptyInput) Read(p []byte) (int, error) {
	return 0, io.EOF
}

// existing prints a notice when a workspace already runs in this cluster: the
// new folder drives it too and the start becomes an upgrade.
func (s *Session) existing(context string) {
	if _, ok := s.run("helm", "status", "devzone-workspace", "--namespace", config.NamespaceWorkspace, exec.HelmContextFlagName, context); ok {
		s.notice()
		return
	}
	if _, ok := s.run("kubectl", "get", "application.argoproj.io", "devzone-workspace", "--namespace", config.NamespaceArgoCD, exec.KubectlContextFlagName, context); ok {
		s.notice()
	}
}

// notice is the single line shown for an already installed workspace.
func (s *Session) notice() {
	fmt.Fprintln(s.Out, "ℹ a devzone workspace already runs in this cluster: this folder drives it too")
}
