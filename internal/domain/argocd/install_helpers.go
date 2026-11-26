package argocd

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
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

// relayStartDirect starts the detached port-forward with the Go relay package,
// in the same folder and with the same target as relay_start of cluster.sh.
func (m *module) relayStartDirect() int {
	err := relay.Start(m.secrets, "argocd", "devzone", m.ns, "svc/argocd-server",
		[]string{m.port + ":443"}, m.launcher)
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	return 0
}

// relayStopDirect stops the argocd relay and removes its PID file.
func (m *module) relayStopDirect() int {
	relay.Stop(m.secrets, "argocd")
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
	return relay.Active(m.secrets, "argocd")
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
