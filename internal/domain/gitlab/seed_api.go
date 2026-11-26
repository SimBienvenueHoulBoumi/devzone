package gitlab

import (
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

func (r *run) apiOK(token, path string) bool {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", baseURL()+path, nil)
	if err != nil {
		return false
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	res, err := client.Do(req)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	return res.StatusCode >= 200 && res.StatusCode < 300
}

// apiJSONField returns a string field of the JSON object at path, like
// `curl ... | jq -r '.field // empty'` (empty when absent or unreadable).
func (r *run) apiJSONField(token, path, field string) string {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", baseURL()+path, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	res, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return jsonField(string(body), field)
}

// execStdin runs kubectl with the script on the standard input.
func (r *run) execStdin(args []string, script string) (exec.Result, error) {
	return r.runner().Run(r.ctx, "kubectl", append([]string{"--context", "devzone"}, args...),
		exec.Opts{Stdin: strings.NewReader(script)})
}

// createRootToken creates a personal access token of the root user through
// gitlab-rails runner on the toolbox pod (never on a command line).
func (r *run) createRootToken(pod string) (string, bool) {
	script := `puts User.find_by_username("root").personal_access_tokens.create(name: "devzone", scopes: ["api", "write_repository"], expires_at: 30.days.from_now).token
`
	res, err := r.execStdin([]string{"exec", "-i", "-n", r.namespace(), pod, "--", "gitlab-rails", "runner", "-"}, script)
	if err != nil || res.Code != 0 {
		return "", false
	}
	token := strings.TrimSpace(lastLine(string(res.Stdout)))
	if token == "" {
		return "", false
	}
	return token, true
}

// lastLine returns the last line of s without its trailing newline
// (shell command substitution + tail -n 1 of the seed).
func lastLine(s string) string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return ""
	}
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}

// seedGroup creates the devzone group when it does not exist; 0 on failure.
func (r *run) seedGroup(token string) int {
	if !r.apiOK(token, "/api/v4/groups/devzone") {
		form := neturl.Values{}
		form.Set("name", "devzone")
		form.Set("path", "devzone")
		form.Set("visibility", "private")
		if _, err := r.apiPostForm(token, "/api/v4/groups", form.Encode()); err != nil {
			fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the devzone group failed, seed stopped.")
			return 1
		}
	}
	if r.apiJSONField(token, "/api/v4/groups/devzone", "id") == "" {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : reading the numeric id of the devzone group failed, seed stopped.")
		return 1
	}
	return 0
}

// seedProject creates the devzone/demo project when it does not exist.
func (r *run) seedProject(token string) int {
	groupID := r.apiJSONField(token, "/api/v4/groups/devzone", "id")
	if groupID == "" {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : reading the numeric id of the devzone group failed, seed stopped.")
		return 1
	}
	if !r.apiOK(token, "/api/v4/projects/devzone%2Fdemo") {
		form := neturl.Values{}
		form.Set("name", "demo")
		form.Set("namespace_id", groupID)
		if _, err := r.apiPostForm(token, "/api/v4/projects", form.Encode()); err != nil {
			fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the devzone/demo project failed, seed stopped.")
			return 1
		}
	}
	return 0
}

// seedDevUser creates the dev user with a random password when it is missing;
// the password is returned when the user is created (an existing user keeps
// its password). The second result is false only when the creation fails.
func (r *run) seedDevUser(token string) (string, bool) {
	users := r.apiGet(token, "/api/v4/users?username=dev")
	if jsonLen(users) != 0 {
		return "", true
	}
	devPassword := randomBase64(18)
	form := neturl.Values{}
	form.Set("email", "dev@gitlab.localhost")
	form.Set("username", "dev")
	form.Set("name", "dev")
	form.Set("skip_confirmation", "true")
	form.Set("password", devPassword)
	if _, err := r.apiPostForm(token, "/api/v4/users", form.Encode()); err != nil {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the dev user failed, seed stopped.")
		return "", false
	}
	return devPassword, true
}

// seedRunnerToken keeps the saved runner token when it is still valid,
// recreates it when refused, stops the seed when the check is impossible
// (seed.sh gitlab_seed).
func (r *run) seedRunnerToken(token string) int {
	if _, err := os.Stat(r.secretsDir() + "/runner-token"); err == nil {
		saved, _ := r.readSecret(r.secretsDir() + "/runner-token")
		form := neturl.Values{}
		form.Set("token", saved)
		code := r.apiStatusCode(token, "POST", "/api/v4/runners/verify", form.Encode())
		switch code {
		case 200:
			fmt.Fprintln(r.out(), "✔ Runner token valid: kept.")
		case 403, 404:
			fmt.Fprintln(r.out(), "devzone : runner token of a previous installation refused: recreated.")
			if !r.createRunnerToken(token) {
				fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the runner token (POST /api/v4/user/runners) failed, seed stopped.")
				return 1
			}
		default:
			fmt.Fprintf(r.errOut(), "devzone : seed GitLab : runner token check impossible (code %d), seed stopped.\n", code)
			return 1
		}
		return 0
	}
	if !r.createRunnerToken(token) {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the runner token (POST /api/v4/user/runners) failed, seed stopped.")
		return 1
	}
	return 0
}

// createRunnerToken creates an instance runner token through the API and
// writes it in the runner-token file (seed.sh, POST /api/v4/user/runners).
func (r *run) createRunnerToken(token string) bool {
	form := neturl.Values{}
	form.Set("runner_type", "instance_type")
	body, err := r.apiPostForm(token, "/api/v4/user/runners", form.Encode())
	newToken := jsonField(body, "token")
	if err != nil || newToken == "" {
		return false
	}
	r.writeFileMode(r.secretsDir()+"/runner-token", newToken)
	return true
}

// createCiJobTokenSigningKey creates the ApplicationSetting value
// ci_job_token_signing_key when the key is missing, via gitlab-rails runner on
// the toolbox pod (idempotent: at a reinstallation without a kept Rails
// secret the setting holds no key and no job would start).
func (r *run) createCiJobTokenSigningKey() int {
	script := `s = ApplicationSetting.first
if s && (s.ci_job_token_signing_key.blank? || s.ci_job_token_signing_key.empty?)
  s.ci_job_token_signing_key = SecureRandom.hex(32)
  s.save!
end
`
	pod, ok := r.readToolboxPod()
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the ci_job_token_signing_key failed.")
		return 1
	}
	res, err := r.execStdin([]string{"exec", "-i", "-n", r.namespace(), pod, "--", "gitlab-rails", "runner", "-"}, script)
	if err != nil || res.Code != 0 {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : creation of the ci_job_token_signing_key failed.")
		return 1
	}
	return 0
}

// seedRunnerSecret creates the Secret of the chart of the runner
// (gitlab-runner-secret) out of Git through kubectl.
func (r *run) seedRunnerSecret() int {
	yaml, err := r.kubectlDevzoneOutput([]string{"create", "secret", "generic", "gitlab-runner-secret",
		"--from-file=runner-token=" + r.secretsDir() + "/runner-token",
		"--from-literal=runner-registration-token=", "--dry-run=client", "-o", "yaml"})
	if err != nil {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : secret gitlab-runner-secret not created, seed stopped.")
		return 1
	}
	res, err := r.runner().Run(r.ctx, "kubectl",
		[]string{"--context", "devzone", "-n", r.namespace(), "apply", "-f", "-"},
		exec.Opts{Stdin: strings.NewReader(yaml)})
	if err != nil || res.Code != 0 {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : secret gitlab-runner-secret not created, seed stopped.")
		return 1
	}
	_, _ = r.kubectlDevzone([]string{"rollout", "restart", "deployment", "--selector=app=gitlab-gitlab-runner"})
	return 0
}

// kubectlDevzoneOutput runs kubectl on the devzone context and returns its stdout.
func (r *run) kubectlDevzoneOutput(args []string) (string, error) {
	res, err := r.kubectlDevzone(args)
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return string(res.Stdout), fmt.Errorf("kubectl: code %d", res.Code)
	}
	return string(res.Stdout), nil
}
