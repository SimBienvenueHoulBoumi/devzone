package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// prepareNamespace creates and labels the namespace and applies isolation policy.
func (m *module) prepareNamespace() int {
	ctxName := m.mgmtCtx()
	res, err := m.kMgmt(ctxName, "create", "namespace", m.ns, "--dry-run=client", "-o", "yaml")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	res, err = m.runWithStdin("kubectl", m.kMgmtArgs(ctxName, "apply", "-f", "-"), string(res.Stdout))
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		return res.Code
	}
	if _, err := m.kMgmt(ctxName, "label", "namespace", m.ns, clusterLabel, "--overwrite"); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if code := m.accountAllow(ctxName, m.ns); code != 0 {
		return code
	}
	if code := m.namespaceIsolate(); code != 0 {
		return code
	}
	return 0
}

// kMgmtArgs builds kubectl args with the management context.
func (m *module) kMgmtArgs(ctxName string, args ...string) []string {
	if ctxName == "" {
		ctxName = m.mgmtCtx()
	}
	full := make([]string, 0, len(args)+2)
	if ctxName != "" {
		full = append(full, "--context", ctxName)
	}
	full = append(full, args...)
	return full
}

// kMgmtEnv returns env for management kubectl calls.
func (m *module) kMgmtEnv(ctxName string) []string {
	if ctxName == "" {
		ctxName = m.mgmtCtx()
	}
	return []string{"KUBECONFIG=" + m.mgmtCfg(ctxName)}
}

// runWithStdin runs a command with stdin content and management kube config env.
func (m *module) runWithStdin(name string, args []string, stdin string) (fexec.Result, error) {
	return m.runner.Run(m.ctx, name, args, fexec.Opts{Stdin: strings.NewReader(stdin), Env: m.kMgmtEnv(m.mgmtCtx())})
}

// accountAllow allows the limited service account in ns, creating account ns/sa if needed.
func (m *module) accountAllow(ctxName, ns string) int {
	acctNS := "devzone-system"
	acctSA := "devzone-agent"
	if _, err := m.kMgmt(ctxName, "create", "namespace", acctNS, "--dry-run=client", "-o", "yaml"); err == nil {
		// create/apply account namespace and service account
	}
	res, err := m.kMgmt(ctxName, "create", "namespace", acctNS, "--dry-run=client", "-o", "yaml")
	if err == nil {
		_, _ = m.runWithStdin("kubectl", m.kMgmtArgs(ctxName, "apply", "-f", "-"), string(res.Stdout))
	}
	res, err = m.kMgmt(ctxName, "-n", acctNS, "create", "serviceaccount", acctSA, "--dry-run=client", "-o", "yaml")
	if err == nil {
		_, _ = m.runWithStdin("kubectl", m.kMgmtArgs(ctxName, "apply", "-f", "-"), string(res.Stdout))
	}
	res, err = m.kMgmt(ctxName, "-n", ns, "create", "rolebinding", acctSA, "--clusterrole=edit", "--serviceaccount="+acctNS+":"+acctSA, "--dry-run=client", "-o", "yaml")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	res, err = m.runWithStdin("kubectl", m.kMgmtArgs(ctxName, "apply", "-f", "-"), string(res.Stdout))
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		return res.Code
	}
	return 0
}

// namespaceIsolate applies the default NetworkPolicy blocking cross-namespace ingress.
func (m *module) namespaceIsolate() int {
	manifest := "apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: devzone-meme-namespace\n  labels:\n    app.kubernetes.io/managed-by: devzone\nspec:\n  podSelector: {}\n  ingress:\n  - from:\n    - podSelector: {}\n"
	res, err := m.runWithStdinCtx("kubectl", m.kubectlArgs("-n", m.ns, "apply", "-f", "-"), manifest, nil)
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		return res.Code
	}
	return 0
}

// runWithStdinCtx runs a command with stdin and optional env.
func (m *module) runWithStdinCtx(name string, args []string, stdin string, env []string) (fexec.Result, error) {
	return m.runner.Run(m.ctx, name, args, fexec.Opts{Stdin: strings.NewReader(stdin), Env: env})
}

// saveAdmin reads the initial admin password secret and writes admin.env (0600).
func (m *module) saveAdmin() int {
	res, err := m.kubectl("-n", m.ns, "get", "secret", "argocd-initial-admin-secret", "-o", "jsonpath={.data.password}")
	if err != nil || res.Code != 0 {
		fmt.Fprintln(m.errOut, "devzone : argocd : secret argocd-initial-admin-secret not found")
		return 1
	}
	pw, ok := decodeB64(strings.TrimSpace(string(res.Stdout)))
	if !ok || pw == "" {
		fmt.Fprintln(m.errOut, "devzone : argocd : admin password unreadable in the secret")
		return 1
	}
	if err := os.MkdirAll(m.secrets, 0o700); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if err := os.Chmod(m.secrets, 0o700); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	content := fmt.Sprintf("ARGOCD_URL=https://127.0.0.1:%s\nARGOCD_USER=admin\nARGOCD_PASSWORD=%s\n", m.port, pw)
	file := filepath.Join(m.secrets, "admin.env")
	if err := writeFile0600(file, []byte(content)); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	return 0
}

// writeFile0600 writes data to path with mode 0600.
func writeFile0600(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}
