package gitlab

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// writeFileMode writes a secret file with mode 600 (shell: umask 077 +
// printf + chmod 600).
func (r *run) writeFileMode(path, content string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(content), 0o600)
	_ = os.Chmod(path, 0o600)
}

// secretsApply applies the Rails secret again from the source file before a
// helm upgrade --install: the chart reuses it, browser sessions stay valid
// after a reinstallation (secrets.sh gitlab_secrets_apply).
func (r *run) secretsApply() {
	if _, err := os.Stat(r.railsFile()); err != nil {
		return
	}
	_, _ = r.kubectlDevzone([]string{"-n", r.namespace(), "apply", "-f", r.railsFile()})
}

// railsSecretMetadataKeys are the metadata fields jq removes from the Rails
// secret: they are specific to the cluster (identity, version, management,
// the annotation of the last apply).
var railsSecretMetadataKeys = []string{
	"resourceVersion", "uid", "creationTimestamp", "managedFields", "ownerReferences",
}

// cleanRailsSecret returns the Rails Secret manifest re-appliable: the fields
// specific to the cluster are removed; empty when the manifest is not JSON.
func cleanRailsSecret(secret string) string {
	var doc map[string]any
	if err := json.Unmarshal([]byte(secret), &doc); err != nil {
		return ""
	}
	metadata, _ := doc["metadata"].(map[string]any)
	if metadata != nil {
		annotations, _ := metadata["annotations"].(map[string]any)
		for _, key := range railsSecretMetadataKeys {
			delete(metadata, key)
		}
		delete(annotations, "kubectl.kubernetes.io/last-applied-configuration")
	}
	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return ""
	}
	return string(out) + "\n"
}

// secretsCopy reads the Rails secret of the cluster and writes a real Secret
// manifest in JSON in workspace/.gitlab/rails-secret.yaml (600, ignored by
// git) on first installation; nothing is written when the read fails or the
// secret is missing (secrets.sh gitlab_secrets_copy).
func (r *run) secretsCopy() {
	secret, err := r.kubectlDevzoneOutput([]string{"get", "secret", "-n", r.namespace(),
		"gitlab-rails-secret", "-o", "json"})
	if err != nil || strings.TrimSpace(secret) == "" {
		return
	}
	cleaned := cleanRailsSecret(secret)
	if cleaned == "" {
		return
	}
	tmp := r.secretsDir() + "/.rails-secret.tmp"
	_ = os.WriteFile(tmp, []byte(cleaned), 0o600)
	_ = os.Chmod(tmp, 0o600)
	_ = os.Rename(tmp, r.railsFile())
}

// secretsWarn warns if the Rails secret could not be kept: the
// reinstallation generates a new secret and the browser sessions are
// invalidated (422) (secrets.sh gitlab_secrets_warn).
func (r *run) secretsWarn() {
	if _, err := os.Stat(r.railsFile()); err != nil {
		fmt.Fprintln(r.out(), "GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost")
	}
}

// newPassword generates a random password for root or dev and applies it
// through gitlab-rails runner on the toolbox pod (never on a command line);
// the source file and the grouped .password are updated when the runner
// confirms. Nothing is shown, only the path (secrets.sh gitlab_new_password).
func (r *run) newPassword(args []string) int {
	var user string
	if len(args) > 0 {
		user = args[0]
	}
	switch user {
	case "root", "dev":
	default:
		display := user
		if display == "" {
			display = "(missing)"
		}
		fmt.Fprintf(r.errOut(), "devzone : gitlab : unknown user : %s (devzone gitlab new-password [root|dev])\n", display)
		return 2
	}
	pass := randomHex(24)
	pod, ok := r.readToolboxPod()
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : gitlab : toolbox pod (label app=toolbox) not found, password not changed.")
		return 1
	}
	script := fmt.Sprintf("u = User.find_by_username(%q)\nu.password = %q\nu.password_confirmation = %q\nu.save!\nputs \"OK\"\n", user, pass, pass)
	output, err := r.execStdinOut([]string{"exec", "-i", "-n", r.namespace(), pod, "--", "gitlab-rails", "runner", "-"}, script)
	if err != nil {
		fmt.Fprintln(r.errOut(), "devzone : gitlab : password (gitlab-rails runner) not applied.")
		return 1
	}
	if !strings.Contains(output, "OK") {
		fmt.Fprintln(r.errOut(), "devzone : gitlab : password not confirmed by gitlab-rails runner.")
		return 1
	}
	r.writeFileMode(r.secretsDir()+"/"+user+"-password", pass)
	if code := r.regeneratePasswords(); code != 0 {
		fmt.Fprintln(r.errOut(), "devzone : gitlab : grouped credentials not updated (devzone passwords)")
	}
	fmt.Fprintln(r.out(), r.root+"/.password")
	return 0
}

// execStdinOut runs kubectl with the script on the standard input and
// returns its stdout (the runner cannot be replaced by an error: the
// caller decides by err).
func (r *run) execStdinOut(args []string, script string) (string, error) {
	res, err := r.runner().Run(r.ctx, "kubectl", append([]string{"--context", "devzone"}, args...),
		exec.Opts{Stdin: strings.NewReader(script)})
	if err != nil {
		return "", err
	}
	return string(res.Stdout), nil
}
