package argocd

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// decodeB64 decodes a standard base64 string.
func decodeB64(s string) (string, bool) {
	if s == "" {
		return "", false
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// regenerateCredentials refreshes the grouped .password view; failure is non-fatal.
func (m *module) regenerateCredentials() {
	res, err := m.runner.Run(m.ctx, "bash", []string{filepath.Join(m.codeRoot, "password.sh"), "regenerate"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		fmt.Fprintln(m.errOut, "devzone : argocd : grouped credentials not updated (devzone passwords)")
	}
}

// relayStart starts or restarts the argocd relay in the container.
func (m *module) relayStart() int {
	// Relay is managed by cluster relay scripts in container; for pod Go command
	// we keep behavior by calling the existing relay helper if present.
	// The shell original calls relay_start argocd devzone devzone-argocd svc/argocd-server 8443:443.
	script := filepath.Join(m.root, ".devcontainer", "devzone")
	_ = script
	return m.relayStartDirect()
}

// relayStartCmd handles "relay-start".
func (m *module) relayStartCmd() int {
	if m.isInstalled() {
		return m.relayStart()
	}
	return 0
}

// relayStopCmd handles "relay-stop".
func (m *module) relayStopCmd() int {
	return m.relayStopDirect()
}

// relayStartDirect starts the port-forward relay loop like cluster.sh relay_start.
func (m *module) relayStartDirect() int {
	dir := filepath.Join(m.root, "workspace", ".argocd")
	_ = dir
	// Use the shell relay library to keep identical behavior.
	cmd := fmt.Sprintf("set -euo pipefail; RACINE=%q; ETAT=%q; . %q; relay_start argocd devzone %s svc/argocd-server %s:443", m.root, m.state, filepath.Join(m.codeRoot, "cluster.sh"), m.ns, m.port)
	res, err := m.runner.Run(m.ctx, "bash", []string{"-c", cmd}, fexec.Opts{})
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		m.out.Write(res.Stdout)
		return res.Code
	}
	return 0
}

// relayStopDirect stops the argocd relay.
func (m *module) relayStopDirect() int {
	cmd := fmt.Sprintf("set -euo pipefail; RACINE=%q; ETAT=%q; . %q; relay_stop argocd", m.root, m.state, filepath.Join(m.codeRoot, "cluster.sh"))
	res, err := m.runner.Run(m.ctx, "bash", []string{"-c", cmd}, fexec.Opts{})
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		m.out.Write(res.Stdout)
		return res.Code
	}
	return 0
}

// status reports the argocd module status string.
func (m *module) status() int {
	if !m.isInstalled() {
		fmt.Fprintln(m.out, "disabled")
		return 0
	}
	if !m.relayActive() {
		fmt.Fprintln(m.out, "ready, relay stopped: devzone apply")
		return 0
	}
	fmt.Fprintf(m.out, "ready: https://127.0.0.1:%s\n", m.port)
	return 0
}

// relayActive reports whether the argocd relay process is running.
func (m *module) relayActive() bool {
	cmd := fmt.Sprintf("set -euo pipefail; RACINE=%q; ETAT=%q; . %q; relay_active argocd", m.root, m.state, filepath.Join(m.codeRoot, "cluster.sh"))
	res, err := m.runner.Run(m.ctx, "bash", []string{"-c", cmd}, fexec.Opts{})
	return err == nil && res.Code == 0
}

// uninstall removes Argo CD, its namespace, secrets and relay.
func (m *module) uninstall() int {
	_ = m.relayStopDirect()
	if m.isInstalled() {
		fmt.Fprintln(m.out, "▶ Deleting Argo CD on the services cluster…")
		ctxName := m.mgmtCtx()
		res, err := m.hMgmt(ctxName, "uninstall", "argocd", "-n", m.ns)
		if err != nil || res.Code != 0 {
			fmt.Fprintln(m.errOut, "devzone : argocd : helm uninstall failed (release already absent?)")
		}
		_, _ = m.kMgmt(ctxName, "-n", m.ns, "delete", "rolebinding", "devzone-agent", "--ignore-not-found")
		_, _ = m.kMgmt(ctxName, "delete", "namespace", m.ns, "--wait=true")
	}
	_ = os.RemoveAll(m.secrets)
	fmt.Fprintln(m.out, "✔ argocd module disabled; the services stay, under direct helm.")
	m.regenerateCredentials()
	return 0
}
