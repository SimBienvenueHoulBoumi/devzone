package clustermenu

import (
	"fmt"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// minikubeProfile is the minikube profile of the local cluster. A profile is a
// different concept from a kubeconfig context, so it keeps its own literal name.
const minikubeProfile = "devzone"

// minikube offers the local cluster: when minikube is missing, it displays the
// official install command (never runs it); otherwise it creates the profile
// devzone after a confirmation, then selects the shared context name.
func (m *Menu) minikube() bool {
	if _, err := m.LookPath("minikube"); err != nil {
		fmt.Fprintln(m.Out, "minikube is not installed. Official command (devzone does not run it):")
		fmt.Fprintln(m.Out, installCommand(m.GOOS))
		fmt.Fprintln(m.Out, "Then run the same command again.")
		return false
	}
	fmt.Fprintln(m.Out, "minikube: devzone will run: minikube start -p devzone (profile devzone, driver chosen by minikube).")
	switch m.ask("Create it now? [y/N] ") {
	case "y", "Y", "yes":
	default:
		fmt.Fprintln(m.Err, "✖ cancelled")
		return false
	}
	res, err := m.Runner.Run(m.Ctx, "minikube", []string{"start", "-p", minikubeProfile}, exec.Opts{})
	// The captured output of minikube is shown after the run, not during it
	m.Out.Write(res.Stdout)
	m.Err.Write(res.Stderr)
	if err != nil || res.Code != 0 {
		fmt.Fprintln(m.Err, "✖ minikube start failed: nothing else done")
		return false
	}
	m.run("kubectl", "config", "use-context", exec.ContextName())
	fmt.Fprintln(m.Out, "✔ minikube cluster devzone started")
	return true
}

// installCommand returns the official install line of minikube for an OS name
// (runtime.GOOS): brew on macOS, a curl line on Linux, winget otherwise.
func installCommand(goos string) string {
	switch goos {
	case "darwin":
		return "  brew install minikube"
	case "linux":
		return "  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube"
	}
	return "  winget install Kubernetes.minikube"
}
