package gitlab

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
	"time"
)

// waitReady waits for the readiness of GitLab with a timeout of GITLAB_ATTENTE
// (default 1200), like gitlab_wait_ready of seed.sh.
func (r *run) waitReady() int {
	attente := os.Getenv("GITLAB_ATTENTE")
	if attente == "" {
		attente = "1200"
	}
	fmt.Fprintf(r.out(), "▶ Waiting for GitLab to be ready (timeout %ss)…\n", attente)
	deadline := r.now().Add(time.Duration(atoiSeconds(attente)) * time.Second)
	for r.now().Before(deadline) {
		if r.curlOK("/-/readiness") || r.curlOK("/users/sign_in") {
			fmt.Fprintln(r.out(), "▶ GitLab ready.")
			return 0
		}
		r.sleep(5 * time.Second)
	}
	fmt.Fprintln(r.errOut(), "devzone : timeout waiting for GitLab.")
	return 1
}

// atoiSeconds parses a shell integer string; 0 on error (bash arithmetic).
func atoiSeconds(s string) int64 {
	n, err := parseInt(s)
	if err != nil {
		return 0
	}
	return n
}

// parseInt parses a string as an int64 (digits only; negative allowed).
func parseInt(s string) (int64, error) {
	sign := int64(1)
	if strings.HasPrefix(s, "-") {
		sign = -1
		s = s[1:]
	}
	if s == "" {
		return 0, fmt.Errorf("not a number")
	}
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("not a number: %s", s)
		}
		n = n*10 + int64(c-'0')
	}
	return sign * n, nil
}

// randomHex returns a random hexadecimal string of n bytes (openssl rand -hex).
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return fmt.Sprintf("%x", b)
}

// randomBase64 returns a random base64 string (openssl rand -base64 18).
func randomBase64(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

// seed fills GitLab with the base data: root token, group devzone, project
// devzone/demo, dev user, runner token and the Secret of the chart (seed.sh
// gitlab_seed).
func (r *run) seed() int {
	fmt.Fprintln(r.out(), "▶ Seeding GitLab…")
	if err := os.MkdirAll(r.secretsDir(), 0o755); err != nil {
		fmt.Fprintf(r.errOut(), "devzone : seed GitLab : %v\n", err)
		return 1
	}

	password, ok := r.readInitialRootPassword()
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : root secret (gitlab-gitlab-initial-root-password) not found, seed stopped.")
		return 1
	}
	r.writeFileMode(r.secretsDir()+"/root-password", password)

	toolboxPod, ok := r.readToolboxPod()
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : toolbox pod (label app=toolbox) not found, seed stopped.")
		return 1
	}
	rootToken, ok := r.createRootToken(toolboxPod)
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the root token (gitlab-rails runner) failed, seed stopped.")
		return 1
	}
	r.writeFileMode(r.rootTokenFile(), rootToken)

	token, _ := r.readSecret(r.rootTokenFile())
	if code := r.seedGroup(token); code != 0 {
		return code
	}
	if code := r.seedProject(token); code != 0 {
		return code
	}
	devPassword, ok := r.seedDevUser(token)
	if !ok {
		return 1
	}
	if devPassword != "" {
		r.writeFileMode(r.secretsDir()+"/dev-password", devPassword)
	}
	if code := r.seedRunnerToken(token); code != 0 {
		return code
	}
	if code := r.createCiJobTokenSigningKey(); code != 0 {
		return code
	}
	if code := r.seedRunnerSecret(); code != 0 {
		return code
	}
	if code := r.pushDemoProject(); code != 0 {
		return code
	}

	fmt.Fprintln(r.out(), "✔ GitLab seed complete.")
	r.regeneratePasswords()
	return 0
}

// seedCommand runs the seed alone, when Argo CD holds the chart (seed.sh
// gitlab_seed_command).
func (r *run) seedCommand() int {
	if code := r.gitlabRelayStart(); code != 0 {
		return code
	}
	if code := r.waitReady(); code != 0 {
		return code
	}
	if code := r.seed(); code != 0 {
		return code
	}
	if _, err := os.Stat(r.railsFile()); err != nil {
		r.secretsCopy()
	}
	return 0
}

// readInitialRootPassword reads the root password of the initial secret of
// GitLab (gitlab-gitlab-initial-root-password, base64) of the namespace.
func (r *run) readInitialRootPassword() (string, bool) {
	res, err := r.kubectlDevzone([]string{"get", "secret", "-n", r.namespace(),
		"gitlab-gitlab-initial-root-password", "-o", "jsonpath={.data.password}"})
	if err != nil || res.Code != 0 {
		return "", false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(res.Stdout)))
	if err != nil || len(raw) == 0 {
		return "", false
	}
	return string(raw), true
}

// readToolboxPod reads the name of the toolbox pod of the namespace.
func (r *run) readToolboxPod() (string, bool) {
	res, err := r.kubectlDevzone([]string{"get", "pod", "-n", r.namespace(), "-l", "app=toolbox",
		"-o", "jsonpath={.items[0].metadata.name}"})
	if err != nil || res.Code != 0 {
		return "", false
	}
	pod := strings.TrimSpace(string(res.Stdout))
	return pod, pod != ""
}
