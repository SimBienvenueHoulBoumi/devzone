package gitlab

import (
	"encoding/json"
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// curlOK reports whether the GitLab of the module answers a 2xx response to
// the path, like curl -sf (the readiness probe of status).
func (r *run) curlOK(path string) bool {
	res, err := http.Get(baseURL() + path)
	if err != nil {
		return false
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, res.Body)
	return res.StatusCode >= 200 && res.StatusCode < 300
}

// apiForm runs a method of the GitLab API of the module with a form body
// (the seed calls it through apiPostForm, a POST).
func (r *run) apiForm(token, method, path, form string) (string, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest(method, baseURL()+path, strings.NewReader(form))
	if err != nil {
		return "", err
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return string(body), fmt.Errorf("HTTP %d", res.StatusCode)
	}
	return string(body), nil
}

// apiGet runs a GET of the GitLab API of the module through the devzone
// context and returns the response body (curl -s --header PRIVATE-TOKEN).
func (r *run) apiGet(token, path string) string {
	client := &http.Client{Timeout: 10 * time.Second}
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
	return string(body)
}

// apiPostForm runs a POST of the GitLab API of the module with a form body.
func (r *run) apiPostForm(token, path, form string) (string, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("POST", baseURL()+path, strings.NewReader(form))
	if err != nil {
		return "", err
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return string(body), fmt.Errorf("HTTP %d", res.StatusCode)
	}
	return string(body), nil
}

// readSecret reads the content of a secret file, trimmed of trailing newlines
// like a shell command substitution; ok=false when the file is absent or empty.
func (r *run) readSecret(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	value := strings.TrimRight(string(data), "\n")
	if value == "" {
		return "", false
	}
	return value, true
}

// apiOnlineRunnerCount returns the number of online runners (the length of the
// JSON array of GET /api/v4/runners/all?status=online); 0 when unreadable.
func (r *run) apiOnlineRunnerCount(token string) int {
	body := r.apiGet(token, "/api/v4/runners/all?status=online")
	var array []any
	if err := json.Unmarshal([]byte(body), &array); err != nil {
		return 0
	}
	return len(array)
}

// installed reports the presence of the namespace of the instance, like
// gitlab_installed (reading the namespaces is reserved to the administrator).
func (r *run) installed() int {
	res, err := r.kubectlAdmin([]string{"get", "namespace", r.namespace()})
	if err != nil || res.Code != 0 {
		return 1
	}
	return 0
}

// status reports the state of GitLab: disabled, ready (runner online or not)
// or failed (gitlab_status).
func (r *run) status() int {
	if r.installed() != 0 {
		fmt.Fprintln(r.out(), "disabled")
		return 0
	}
	if !r.curlOK("/-/readiness") && !r.curlOK("/users/sign_in") {
		fmt.Fprintln(r.out(), "failed: devzone apply")
		return 0
	}
	runnerStatus := "offline"
	if token, ok := r.readSecret(r.rootTokenFile()); ok {
		if r.apiOnlineRunnerCount(token) > 0 {
			runnerStatus = "online"
		}
	}
	fmt.Fprintf(r.out(), "ready: %s, runner %s\n", config.GitLab().WebURL(), runnerStatus)
	return 0
}

// pipelineTimeout is the ceiling of the pipeline wait started at the end of
// the installation (GITLAB_TEST_PIPELINE in the tests of the shell entry).
const pipelineTimeout = 600 * time.Second

// pipelineLaunch starts the pipeline of the demo project of the instance at
// the end of the installation and, when it fails, records the reason in the
// failure marker of the module, like applyGitlab of internal/podcmd/modules_change.go.
func (r *run) pipelineLaunch() {
	token, ok := r.readSecret(r.rootTokenFile())
	if !ok {
		r.writePipelineFailure("root token not found")
		return
	}
	body, err := r.apiPostForm(token, "/projects/devzone%2Fdemo/pipeline", "ref=main")
	if err != nil {
		r.writePipelineFailure("creation of the pipeline of devzone/demo impossible")
		return
	}
	id := jsonField(body, "id")
	if id == "" {
		r.writePipelineFailure("pipeline creation response without id")
		return
	}
	start := r.now()
	for {
		body := r.apiGet(token, "/projects/devzone%2Fdemo/pipelines/"+id)
		state := jsonField(body, "status")
		switch state {
		case "success":
			return
		case "failed", "canceled", "skipped":
			r.writePipelineFailure("pipeline " + state)
			return
		}
		if r.now().Sub(start) >= pipelineTimeout {
			r.writePipelineFailure("timeout " + strconv.FormatInt(int64(pipelineTimeout/time.Second), 10) + " s exceeded (state " + state + ")")
			return
		}
		r.sleep(5 * time.Second)
	}
}

// jsonField returns the string value of a key of a small JSON object (numbers
// are printed as decimal strings, like jq -r).
func jsonField(body, key string) string {
	var v map[string]any
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		return ""
	}
	switch value := v[key].(type) {
	case string:
		return value
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", value)
	}
}

// writePipelineFailure writes the reason of a failed pipeline to the failure
// marker of the module (the content is where devzone-status.sh looks).
func (r *run) writePipelineFailure(reason string) {
	marker := r.state + "-failed-gitlab"
	_ = os.WriteFile(marker, []byte(reason+"\n"), 0o644)
}

// apiStatusCode returns the HTTP status of a request to the GitLab API of the
// module, 0 on any error (curl -s -o /dev/null -w '%{http_code}' with a
// method and a form body).
func (r *run) apiStatusCode(token, method, path, form string) int {
	client := &http.Client{Timeout: 30 * time.Second}
	var body io.Reader
	if form != "" {
		body = strings.NewReader(form)
	}
	req, err := http.NewRequest(method, baseURL()+path, body)
	if err != nil {
		return 0
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	if form != "" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	res, err := client.Do(req)
	if err != nil {
		return 0
	}
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	return res.StatusCode
}

// jsonLen returns the length of the JSON array of body, 0 when unreadable.
func jsonLen(body string) int {
	var array []any
	if err := json.Unmarshal([]byte(body), &array); err != nil {
		return 0
	}
	return len(array)
}
