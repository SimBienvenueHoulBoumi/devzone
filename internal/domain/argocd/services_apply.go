package argocd

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// randRead fills b with cryptographic random bytes.
func randRead(b []byte) (int, error) { return rand.Read(b) }

// servicesApplicationApply applies devzone-<svc> Application.
func (m *module) servicesApplicationApply(svc string) int {
	if rc := m.chartRequire(svc); rc != 0 {
		return rc
	}
	repoURL := os.Getenv("DEVZONE_REPO_URL")
	if repoURL == "" {
		repoURL = "https://github.com/SimBienvenueHoulBoumi/devzone.git"
	}
	params := []string{}
	if svc == "mysql" {
		p, rc := m.servicesChartMySQL()
		if rc != 0 {
			return rc
		}
		params = append(params, p...)
	}
	return m.gitopsApplyApplication("devzone-"+svc, "service", "devzone-"+svc, repoURL, m.argocdRevision(), "charts/devzone-"+svc, params...)
}

// servicesChartMySQL returns Helm params for mysql chart.
func (m *module) servicesChartMySQL() ([]string, int) {
	image, port, memory, size := "mysql:8.4", "3306", "1Gi", "5Gi"
	// read app.conf if present
	conf := filepath.Join(m.codeRoot, "catalog", "mysql", "app.conf")
	if data, err := os.ReadFile(conf); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "image=") {
				image = strings.TrimPrefix(line, "image=")
			} else if strings.HasPrefix(line, "port=") {
				port = strings.TrimPrefix(line, "port=")
			} else if strings.HasPrefix(line, "memoire=") {
				memory = strings.TrimPrefix(line, "memoire=")
			} else if strings.HasPrefix(line, "taille=") {
				size = strings.TrimPrefix(line, "taille=")
			}
		}
	}
	claim := ""
	res, err := m.kubectl("-n", "devzone-mysql", "get", "pvc", "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
	if err == nil && res.Code == 0 {
		var claims []string
		for _, line := range strings.Split(string(res.Stdout), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasSuffix(line, "-mysql-0") {
				claims = append(claims, line)
			}
		}
		if len(claims) > 1 {
			fmt.Fprintln(m.errOut, "✖ several MySQL volumes in devzone-mysql: devzone mysql volume <name> picks the mounted one")
			return nil, 2
		}
		if len(claims) == 1 {
			claim = strings.TrimSuffix(claims[0], "-mysql-0")
		}
	}
	params := []string{"image=" + image, "port=" + port, "memory=" + memory, "size=" + size}
	if claim != "" {
		params = append(params, "claim="+claim)
	}
	return params, 0
}

// hookWait waits for service pods to become ready.
func (m *module) hookWait(svc string) int {
	ns := "devzone-" + svc
	for i := 0; i < 60; i++ {
		res, err := m.kubectl("-n", ns, "get", "pods", "-o", "name")
		if err == nil && res.Code == 0 && strings.TrimSpace(string(res.Stdout)) != "" {
			res, err = m.kubectl("-n", ns, "wait", "--for=condition=Ready", "pod", "--all", "--timeout=300s")
			if err == nil && res.Code == 0 {
				return 0
			}
		}
		// sleep 5s
		if _, err := m.runner.Run(m.ctx, "bash", []string{"-c", "sleep 5"}, noStdin()); err != nil {
			return 1
		}
	}
	fmt.Fprintf(m.errOut, "✖ %s : pods not ready in devzone-%s (devzone argocd status)\n", svc, svc)
	return 1
}

// hookRelay starts the relay for a service.
func (m *module) hookRelay(svc string) int {
	script := ""
	switch svc {
	case "postgres":
		script = filepath.Join(m.codeRoot, "postgres", "postgres.sh")
	case "mysql":
		script = filepath.Join(m.codeRoot, "catalog", "mysql", "mysql.sh")
	default:
		return 1
	}
	res, err := m.runner.Run(m.ctx, "bash", []string{script, "relay-start"}, noStdin())
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		if res.Code != 0 {
			m.errOut.Write(res.Stderr)
			m.out.Write(res.Stdout)
			return res.Code
		}
		return 1
	}
	m.out.Write(res.Stdout)
	return 0
}
