package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// applyModule installs ("on") or removes ("off") a module (apply_<module>).
func (m *modules) applyModule(verb, module string, extra []string) int {
	switch module {
	case "kubernetes":
		return m.applyKubernetes(verb)
	case "gitlab":
		return m.applyGitlab(verb)
	case "postgres":
		return m.applyPostgres(verb, extra)
	case "argocd":
		return m.applyArgocd(verb)
	case "mysql":
		return m.applyMysql(verb)
	}
	return 0
}

// apply runs the module steps of devzone apply: the migrations, the
// confirmation of the state, the repository, then each module that is on.
func (m *modules) apply() int {
	m.migrateLLM()
	if code := m.call(m.ctx.Out, "state", "recovery-confirm"); code != 0 {
		return code
	}
	if code := m.call(m.ctx.Out, "apply-repowarden"); code != 0 {
		return code
	}
	if m.value("ai") != "off" {
		if code := m.call(m.ctx.Out, "ai", "apply", "on"); code != 0 {
			return code
		}
	}
	// gitlab, postgres, argocd: installed from the workstation in the
	// Kubernetes workspace pod (#528), by their installer elsewhere
	if m.value("gitlab") != "off" {
		if code := m.applyService("gitlab"); code != 0 {
			return code
		}
	}
	if m.value("postgres") != "off" {
		if code := m.applyService("postgres"); code != 0 {
			return code
		}
	}
	if m.value("mysql") != "off" {
		if code := m.applyMysql("on"); code != 0 {
			return code
		}
	}
	if m.value("argocd") != "off" {
		if code := m.applyService("argocd"); code != 0 {
			return code
		}
	}
	return 0
}

// applyService installs a service module when devzone apply starts it. In the
// pod nothing is installed (the workstation does it, #528) and the failure
// marker of an earlier start is cleared (apply_service).
func (m *modules) applyService(module string) int {
	if m.inPod {
		m.clearMarker(module)
		fmt.Fprintf(m.ctx.Out, "devzone: %s is installed from the workstation (devzone workspace services enable %s): nothing to do in the pod\n", module, module)
		return 0
	}
	return m.applyModule("on", module, nil)
}

// applyKubernetes connects the clusters from the workstation (nothing to run on
// "on"); "off" removes the host kubeconfig and metrics-server (apply_kubernetes).
func (m *modules) applyKubernetes(verb string) int {
	if verb == "on" {
		return 0
	}
	_ = os.Remove(filepath.Join(m.home, ".kube", "hote.config"))
	// metrics-server removed from the clusters where devzone installed it
	_ = m.call(m.ctx.Out, "metrics", "remove")
	fmt.Fprintln(m.ctx.Out, "devzone : kubernetes disabled")
	return 0
}

// applyArgocd starts Argo CD in the services cluster, reached through the relay
// 127.0.0.1:8443; a failure is marked in the state (apply_argocd, #411).
func (m *modules) applyArgocd(verb string) int {
	out := m.ctx.Out
	if verb != "on" {
		if code := m.call(out, "argocd", "uninstall"); code != 0 {
			return code
		}
		m.clearMarker("argocd")
		return 0
	}
	current, _ := m.capture("argocd", "status")
	// "relay stopped" first: this line also starts with "ready"
	switch {
	case strings.Contains(current, "relay stopped"):
		if code := m.call(out, "argocd", "relay-start"); code != 0 {
			return code
		}
		fmt.Fprintln(out, "devzone : argocd : relay restarted")
	case strings.HasPrefix(current, "ready"):
		fmt.Fprintln(out, "devzone : argocd already active, nothing to do.")
	default:
		if m.call(out, "argocd", "install") != 0 {
			m.setMarker("argocd")
			return 1
		}
	}
	m.clearMarker("argocd")
	return 0
}

// runApply handles "devzone apply" in Go: the modules that are on are installed
// or started again.
func runApply(ctx *cli.Context) int {
	return newModules(ctx).apply()
}
