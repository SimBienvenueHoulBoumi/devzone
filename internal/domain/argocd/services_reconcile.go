package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// hookOn enables a service through Argo CD.
func (m *module) hookOn(svc string) int {
	active, err := m.catalogArgocdActive(svc)
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if !active {
		return 3
	}
	if code := m.servicesNote(svc, "on"); code != 0 {
		return 1
	}
	if code := m.servicesReconcile(); code != 0 {
		return 1
	}
	revision, err := m.argocdRevision()
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	fmt.Fprintf(m.out, "▶ %s as an Argo CD Application (charts/devzone-%s at %s)…\n", svc, svc, revision)
	if code := m.hookWait(svc); code != 0 {
		return 1
	}
	if code := m.hookRelay(svc); code != 0 {
		return 1
	}
	fmt.Fprintf(m.out, "✔ %s held by Argo CD ([services] %s = on in .argocd.conf)\n", svc, svc)
	return 0
}

// hookOff removes a service Application through Argo CD.
func (m *module) hookOff(svc string) int {
	if !m.catalogArgocdApplicationExists(svc) {
		return 3
	}
	if code := m.servicesNote(svc, "off"); code != 0 {
		return 1
	}
	if code := m.gitopsDeleteApplication("devzone-"+svc, "cascade"); code != 0 {
		return 1
	}
	fmt.Fprintf(m.out, "✔ Application devzone-%s removed (its resources leave with it)\n", svc)
	return 3
}

// hookRelease releases postgres/mysql/gitlab Applications when argocd module is disabled.
func (m *module) hookRelease() int {
	for _, svc := range []string{"postgres", "mysql", "gitlab"} {
		app := "devzone-" + svc
		res, err := m.kubectl("-n", "devzone-argocd", "get", "application.argoproj.io", app)
		if err != nil || res.Code != 0 {
			continue
		}
		_, _ = m.kubectl("-n", "devzone-argocd", "patch", "application.argoproj.io", app, "--type", "merge", "-p", `{"metadata":{"finalizers":null}}`)
		if code := m.gitopsDeleteApplication(app, "keep"); code != 0 {
			return 1
		}
		if svc == "postgres" || svc == "mysql" {
			if code := m.servicesNote(svc, "off"); code != 0 {
				return 1
			}
		}
		fmt.Fprintf(m.out, "✔ Application %s released: its resources stay for the helm-direct path\n", app)
	}
	return 3
}

// catalogArgocdApplicationExists reports whether devzone-<app> Application exists.
func (m *module) catalogArgocdApplicationExists(app string) bool {
	data, _ := os.ReadFile(m.state)
	on := false
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "argocd=on" {
			on = true
		}
	}
	if !on {
		return false
	}
	res, err := m.kubectl("-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-"+app)
	return err == nil && res.Code == 0
}

// servicesReconcile applies or removes service Applications from [services].
func (m *module) servicesReconcile() int {
	code := 0
	for _, svc := range servicesList {
		state := m.servicesStateOf(svc)
		switch state {
		case "on":
			if rc := m.chartRequire(svc); rc != 0 {
				if rc > code {
					code = rc
				}
				continue
			}
			if rc := m.servicesNamespacePrepare(svc); rc != 0 {
				fmt.Fprintf(m.errOut, "✖ %s: namespace step failed\n", svc)
				if code == 0 {
					code = 1
				}
				continue
			}
			if rc := m.servicesSecret(svc); rc != 0 {
				fmt.Fprintf(m.errOut, "✖ %s: secret step failed\n", svc)
				if code == 0 {
					code = 1
				}
				continue
			}
			if rc := m.servicesApplicationApply(svc); rc != 0 {
				fmt.Fprintf(m.errOut, "✖ %s: declare step failed\n", svc)
				if code == 0 {
					code = 1
				}
				continue
			}
			fmt.Fprintf(m.out, "✔ Application devzone-%s declared (chart charts/devzone-%s)\n", svc, svc)
		case "off":
			if rc := m.gitopsDeleteApplication("devzone-"+svc, "cascade"); rc != 0 {
				fmt.Fprintf(m.errOut, "✖ %s: remove step failed\n", svc)
				if code == 0 {
					code = 1
				}
				continue
			}
			fmt.Fprintf(m.out, "✔ Application devzone-%s removed (namespace and volumes kept)\n", svc)
		}
	}
	return code
}

// servicesNamespacePrepare creates and isolates the service namespace.
func (m *module) servicesNamespacePrepare(svc string) int {
	ns := "devzone-" + svc
	res, err := m.kubectl("create", "namespace", ns, "--dry-run=client", "-o", "yaml")
	if err != nil {
		return 1
	}
	res, err = m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("apply", "-f", "-"), fexec.Opts{Stdin: strings.NewReader(string(res.Stdout))})
	if err != nil || res.Code != 0 {
		return 1
	}
	_, _ = m.kubectl("label", "namespace", ns, "app.kubernetes.io/managed-by=devzone", "--overwrite")
	manifest := "apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: devzone-meme-namespace\n  labels:\n    app.kubernetes.io/managed-by: devzone\nspec:\n  podSelector: {}\n  ingress:\n  - from:\n    - podSelector: {}\n"
	res, err = m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", ns, "apply", "-f", "-"), fexec.Opts{Stdin: strings.NewReader(manifest)})
	if err != nil || res.Code != 0 {
		return 1
	}
	return 0
}

// servicesSecret creates the superuser secret for a service.
func (m *module) servicesSecret(svc string) int {
	switch svc {
	case "postgres":
		return m.servicesSecretAdmin("postgres", "devzone-postgres", "postgres-admin")
	case "mysql":
		return m.servicesSecretAdmin("mysql", "devzone-mysql", "mysql-admin")
	default:
		fmt.Fprintf(m.errOut, "✖ no secret hook for %s (services_secret_%s): the sync will fail\n", svc, svc)
		return 1
	}
}

// servicesSecretAdmin creates or mirrors the admin secret for a service.
func (m *module) servicesSecretAdmin(svc, ns, secret string) int {
	dir := filepath.Join(m.root, "workspace", "."+svc)
	file := filepath.Join(dir, "admin-password")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return 1
	}
	_ = os.Chmod(dir, 0o700)
	res, err := m.kubectl("-n", ns, "get", "secret", secret, "-o", "jsonpath={.data.password}")
	password := ""
	if err == nil && res.Code == 0 {
		if pw, ok := decodeB64(strings.TrimSpace(string(res.Stdout))); ok {
			password = pw
		}
	}
	if password != "" {
		if err := writeFile0600(file, []byte(password)); err != nil {
			return 1
		}
		m.regenerateCredentials()
		return 0
	}
	if data, err := os.ReadFile(file); err == nil && len(data) > 0 {
		password = string(data)
	} else {
		password = randomHex(24)
		if err := writeFile0600(file, []byte(password)); err != nil {
			return 1
		}
	}
	// create secret --from-file=password=file
	res, err = m.kubectl("-n", ns, "create", "secret", "generic", secret, "--from-file=password="+file)
	if err != nil || res.Code != 0 {
		return 1
	}
	if err := writeFile0600(file, []byte(password)); err != nil {
		return 1
	}
	m.regenerateCredentials()
	return 0
}

// randomHex returns n random bytes hex-encoded (2n chars), like openssl rand -hex n.
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := randRead(b); err != nil {
		// deterministic fallback should never happen, but keep function total
		for i := range b {
			b[i] = byte(i)
		}
	}
	const hexdigits = "0123456789abcdef"
	out := make([]byte, n*2)
	for i, v := range b {
		out[i*2] = hexdigits[v>>4]
		out[i*2+1] = hexdigits[v&0x0f]
	}
	return string(out)
}
