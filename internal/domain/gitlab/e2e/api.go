package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// httpClient has a bounded timeout: a step never waits forever for an answer.
var httpClient = http.Client{Timeout: 10 * time.Second}

// apiClient calls the GitLab API with the root token in a header, as the seed
// does. The token is never part of the URL or of a command argument.
type apiClient struct {
	base   string
	token  string
	client *http.Client
}

// call sends one API request with an optional form body and returns its answer.
func (a *apiClient) call(method, path string, form url.Values) ([]byte, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequest(method, a.base+"/api/v4"+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("PRIVATE-TOKEN", a.token)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	res, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return data, fmt.Errorf("api %s %s: status %d", method, path, res.StatusCode)
	}
	return data, nil
}

// jsonField returns one string field of a JSON answer, empty when missing.
func jsonField(data []byte, name string) string {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err != nil {
		return ""
	}
	raw, ok := obj[name]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String()
	}
	return ""
}

// readToken loads the root token of the instance and explains a missing or
// empty file without ever showing its content.
func (s *session) readToken() bool {
	path := filepath.Join(s.root, "workspace", ".gitlab", "root-token")
	data, err := os.ReadFile(path)
	if err != nil {
		s.reason("root token missing (%s): run with the devzone test-gitlab command of the PATH, or set DEVZONE_ROOT to the root of the enabled repository", path)
		return false
	}
	s.api.token = strings.TrimSpace(string(data))
	if s.api.token == "" {
		s.reason("root token empty (%s)", path)
		return false
	}
	return true
}

// deleteKey removes the throwaway SSH key put on GitLab for the clone step.
func (s *session) deleteKey() {
	if s.keyID == "" {
		return
	}
	_, _ = s.api.call(http.MethodDelete, "/user/keys/"+s.keyID, nil)
	s.keyID = ""
}

// masked replaces every occurrence of the token in a suite output, so that a
// failure log can be kept without showing a secret.
func (s *session) masked(text string) string {
	if s.api.token == "" {
		return text
	}
	return strings.ReplaceAll(text, s.api.token, "TOKEN_MASKED")
}

// stringLines splits text into lines and drops the trailing empty one.
func stringLines(text string) []string {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// cutPrefix removes prefix from s and reports whether it was present.
func cutPrefix(s, prefix string) (string, bool) {
	if !strings.HasPrefix(s, prefix) {
		return "", false
	}
	return strings.TrimSuffix(strings.TrimPrefix(s, prefix), "\r"), true
}

// tempDir creates a throwaway folder tracked for cleanup.
func (s *session) tempDir(prefix string) (string, error) {
	dir, err := s.mkdirTemp(prefix)
	if err == nil {
		s.tempDirs = append(s.tempDirs, dir)
	}
	return dir, err
}

// containsToken reports whether a file holds the secret of the session.
func (s *session) containsToken(path string) bool {
	data, err := os.ReadFile(path)
	return err == nil && bytes.Contains(data, []byte(s.api.token))
}
