package argocd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

const (
	defaultNS            = "devzone-argocd"
	defaultVersion       = "10.14.0"
	defaultPort          = "8443"
	defaultWait          = "600"
	minMemoryKi    int64 = 1048576
	clusterLabel         = "app.kubernetes.io/managed-by=devzone"
)

// module holds the resolved paths and collaborators of one argocd command.
type module struct {
	ctx      context.Context
	runner   fexec.Runner
	launcher relay.Launcher
	out      io.Writer
	errOut   io.Writer
	root     string
	codeRoot string
	state    string
	host     string
	config   string
	secrets  string
	ns       string
	version  string
	port     string
	wait     string
}

// chartPath returns the chart folder of a service in the shipped code tree,
// not under the instance root that only holds state and workspace secrets.
func (m *module) chartPath(svc string) string {
	return filepath.Join(filepath.Dir(m.codeRoot), "charts", "devzone-"+svc)
}

// refuse prints the module refusal message and returns code 2.
func (m *module) refuse(msg string, args ...any) int {
	fmt.Fprintf(m.errOut, "devzone : argocd : "+msg+"\n", args...)
	return 2
}

// st returns the state handle for the module state file.
func (m *module) st() *state.State { return state.New(m.state) }

// clusterSaved returns the chosen services cluster context, or empty.
func (m *module) clusterSaved() string { return m.st().Get("cluster") }

// currentContext returns the current kubectl context.
func (m *module) currentContext() string {
	res, err := m.runner.Run(m.ctx, "kubectl", []string{"config", "current-context"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// mgmtCtx returns the management context: saved cluster, then current context.
func (m *module) mgmtCtx() string {
	if c := m.clusterSaved(); c != "" {
		return c
	}
	return m.currentContext()
}

// mgmtCfg returns the kube config file that holds the given management context.
func (m *module) mgmtCfg(ctxName string) string {
	kcfg := "KUBECONFIG"
	if ctxName == "" || !isFile(m.host) {
		return m.config
	}
	res, err := m.runner.Run(m.ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Opts{Env: []string{kcfg + "=" + m.host}})
	if err != nil || res.Code != 0 {
		return m.config
	}
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(line) == ctxName {
			return m.host
		}
	}
	return m.config
}

// isFile reports whether path is an existing regular file.
func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// kMgmt runs kubectl with the explicit kube config holding ctxName.
func (m *module) kMgmt(ctxName string, args ...string) (fexec.Result, error) {
	kcfg := "KUBECONFIG"
	if ctxName == "" {
		ctxName = m.mgmtCtx()
	}
	conf := m.mgmtCfg(ctxName)
	full := make([]string, 0, len(args)+2)
	if ctxName != "" {
		full = append(full, "--context", ctxName)
	}
	full = append(full, args...)
	return m.runner.Run(m.ctx, "kubectl", full, fexec.Opts{Env: []string{kcfg + "=" + conf}})
}

// hMgmt runs helm with the explicit kube config holding ctxName.
func (m *module) hMgmt(ctxName string, args ...string) (fexec.Result, error) {
	if ctxName == "" {
		ctxName = m.mgmtCtx()
	}
	conf := m.mgmtCfg(ctxName)
	full := []string{"--kubeconfig", conf}
	if ctxName != "" {
		full = append(full, fexec.HelmContextFlagName, ctxName)
	}
	full = append(full, args...)
	return m.runner.Run(m.ctx, "helm", full, fexec.Opts{})
}

// kubectlArgs prepends the shared services context flag to a kubectl call, so
// every Argo CD command selects that context only when kubeconfig declares it.
func (m *module) kubectlArgs(args ...string) []string {
	return append(fexec.DevzoneContextFlag(m.ctx, m.runner, "--context"), args...)
}

// kubectl runs kubectl on the services cluster, as the limited account does.
func (m *module) kubectl(args ...string) (fexec.Result, error) {
	return m.runner.Run(m.ctx, "kubectl", m.kubectlArgs(args...), fexec.Opts{})
}

// isInstalled reports whether the Argo CD namespace exists.
func (m *module) isInstalled() bool {
	res, err := m.kMgmt(m.mgmtCtx(), "get", "namespace", m.ns)
	return err == nil && res.Code == 0
}
