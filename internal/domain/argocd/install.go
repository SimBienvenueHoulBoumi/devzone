package argocd

import (
	"fmt"
	"strconv"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// install installs Argo CD in the services cluster.
func (m *module) install() int {
	fmt.Fprintln(m.out, "▶ Checking the allocatable memory of the services cluster…")
	if code := m.checkMemory(); code != 0 {
		return code
	}
	if code := m.prepareNamespace(); code != 0 {
		return code
	}
	fmt.Fprintf(m.out, "▶ Installing Argo CD %s in %s (chart charts/devzone-argocd)…\n", m.version, m.ns)
	chart := m.chartPath("argocd")
	res, err := m.runner.Run(m.ctx, "helm", []string{"dependency", "build", chart}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return m.failCmd("helm dependency build", res, err)
	}
	ctxName := m.mgmtCtx()
	res, err = m.hMgmt(ctxName, "upgrade", "--install", "argocd", chart, "--namespace", m.ns, "--create-namespace", "--timeout", m.wait+"s", "--wait")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		m.errOut.Write(res.Stdout)
		return res.Code
	}
	if code := m.saveAdmin(); code != 0 {
		return code
	}
	if code := m.relayStart(); code != 0 {
		return code
	}
	m.regenerateCredentials()
	fmt.Fprintf(m.out, "✔ argocd module ready: https://127.0.0.1:%s\n", m.port)
	return 0
}

// failCmd reports a command failure and returns a non-zero code.
func (m *module) failCmd(name string, res fexec.Result, err error) int {
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if len(res.Stderr) > 0 {
		m.errOut.Write(res.Stderr)
	}
	if len(res.Stdout) > 0 {
		m.errOut.Write(res.Stdout)
	}
	if res.Code != 0 {
		return res.Code
	}
	return 1
}

// checkMemory refuses installation when the cluster has less than 1 Gi allocatable.
func (m *module) checkMemory() int {
	lines, ok := m.nodeAllocatable()
	if !ok {
		fmt.Fprintln(m.errOut, "devzone : argocd : services cluster unreachable: devzone cluster")
		return 2
	}
	total := int64(0)
	for _, v := range lines {
		total += quantityKi(v)
	}
	if total < minMemoryKi {
		fmt.Fprintf(m.errOut, "devzone : argocd : at least 1 GB of allocatable memory is needed in the cluster (available: %d MB); enlarge the cluster (Docker Desktop → Settings → Resources) then run again: devzone enable argocd\n", total/1024)
		return 2
	}
	return 0
}

// nodeAllocatable returns allocatable memory quantities for each node.
func (m *module) nodeAllocatable() ([]string, bool) {
	res, err := m.kubectl("get", "nodes", "-o", "jsonpath={range .items[*]}{.status.allocatable.memory}{\"\\n\"}{end}")
	if err != nil || res.Code != 0 {
		return nil, false
	}
	out := strings.TrimRight(string(res.Stdout), "\n")
	if out == "" {
		return nil, false
	}
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) == 0 {
		return nil, false
	}
	return lines, true
}

// quantityKi converts a Kubernetes quantity string to KiB.
func quantityKi(q string) int64 {
	if n, ok := parseQty(q, "Ki"); ok {
		return n
	}
	if n, ok := parseQty(q, "Mi"); ok {
		return n * 1024
	}
	if n, ok := parseQty(q, "Gi"); ok {
		return n * 1024 * 1024
	}
	if n, ok := parseQty(q, "Ti"); ok {
		return n * 1024 * 1024 * 1024
	}
	if n, ok := parseQty(q, "K"); ok {
		return n * 1000 / 1024
	}
	if n, ok := parseQty(q, "k"); ok {
		return n * 1000 / 1024
	}
	if n, ok := parseQty(q, "M"); ok {
		return n * 1000 * 1000 / 1024
	}
	if n, ok := parseQty(q, "G"); ok {
		return n * 1000 * 1000 * 1000 / 1024
	}
	if q == "" {
		return 0
	}
	for _, c := range q {
		if c < '0' || c > '9' {
			return 0
		}
	}
	n, err := strconv.ParseInt(q, 10, 64)
	if err != nil {
		return 0
	}
	return n / 1024
}

// parseQty parses an integer quantity with a suffix.
func parseQty(q, suffix string) (int64, bool) {
	if !strings.HasSuffix(q, suffix) {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSuffix(q, suffix), 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}
