package e2e

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// stepClones clones devzone/demo over SSH and HTTP with a throwaway key. The
// HTTP token is read by a credential helper, never passed in an argument, the
// URL or the config of the clone.
func stepClones(s *session) (int, string) {
	if !s.readToken() {
		return 1, s.current
	}
	dir, err := s.tempDir("devzone-test-gitlab-clones.XXXXXX")
	if err != nil {
		return 1, "temporary directory impossible"
	}
	key := filepath.Join(dir, "id_ed25519")
	res, err := s.run("ssh-keygen", []string{"-q", "-t", "ed25519", "-N", "", "-f", key})
	if err != nil || res.Code != 0 {
		return 1, "ed25519 key generation impossible"
	}
	pub, _ := os.ReadFile(key + ".pub")
	form := url.Values{"title": {"devzone test-gitlab"}, "key": {string(pub)}}
	data, err := s.api.call(http.MethodPost, "/user/keys", form)
	if err != nil {
		return 1, "SSH key upload to GitLab impossible"
	}
	s.keyID = jsonField(data, "id")
	if s.keyID == "" {
		return 1, "key upload response without id"
	}
	sshCmd := fmt.Sprintf("ssh -i %s -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new",
		key, filepath.Join(dir, "known_hosts"))
	res, err = s.run("git", []string{"clone", "-q", "-c", "core.sshCommand=" + sshCmd,
		"ssh://git@gitlab.localhost:2224/devzone/demo.git", filepath.Join(dir, "ssh-demo")})
	if err != nil || res.Code != 0 {
		return 1, "SSH clone (ssh://git@gitlab.localhost:2224/devzone/demo.git) impossible"
	}
	helper := "!f() { echo username=oauth2; printf 'password='; cat \"" +
		filepath.Join(s.root, "workspace", ".gitlab", "root-token") + "\"; echo; }; f"
	res, err = s.run("git", []string{"-c", "credential.helper=", "-c", "credential.helper=" + helper,
		"clone", "-q", s.api.base + "/devzone/demo.git", filepath.Join(dir, "http-demo")})
	if err != nil || res.Code != 0 {
		return 1, "HTTP clone of devzone/demo impossible"
	}
	if s.containsToken(filepath.Join(dir, "http-demo", ".git", "config")) {
		return 1, "the token was written to .git/config of the clone"
	}
	return 0, ""
}

// stepPlatform switches to the gitlab platform, clones with glab, then returns
// to the platform chosen before the test. The cleanup restores it even when
// this step fails midway.
func stepPlatform(s *session) (int, string) {
	dir, err := s.tempDir("devzone-test-gitlab-plateforme.XXXXXX")
	if err != nil {
		return 1, "temporary directory impossible"
	}
	s.changed = true
	res, err := s.run(s.devzone, []string{"platform", "gitlab"})
	if err != nil || res.Code != 0 {
		return 1, "devzone platform gitlab failed"
	}
	res, err = s.run(s.glab, []string{"repo", "clone", "devzone/demo", filepath.Join(dir, "demo")})
	if err != nil || res.Code != 0 {
		return 1, "glab repo clone devzone/demo failed"
	}
	if err := s.restorePlatform(); err != nil {
		return 1, fmt.Sprintf("return to platform %s impossible", s.platform)
	}
	if s.platform == "github" {
		if exists(s.glab) || exists(filepath.Join(s.home, ".config", "glab-cli")) {
			return 1, "glab or its configuration remains after returning to github"
		}
	}
	s.changed = false
	return 0, ""
}

// stepRepowarden runs the integration suite of repowarden against the instance.
// A missing suite is skipped; a failure keeps a log with the token masked.
func stepRepowarden(s *session) (int, string) {
	if !s.readToken() {
		return 1, s.current
	}
	dir, err := s.tempDir("devzone-test-gitlab-repowarden.XXXXXX")
	if err != nil {
		return 1, "temporary directory impossible"
	}
	ref := s.opts.Ref
	if ref == "" {
		ref = os.Getenv("REPOWARDEN_TEST_REF")
	}
	if ref == "" {
		ref = "develop"
	}
	res, err := s.run("git", []string{"clone", "-q", "--depth", "1", "--branch", ref,
		"https://github.com/simdevWarden/repowarden.git", filepath.Join(dir, "repowarden")})
	if err != nil || res.Code != 0 {
		return 1, fmt.Sprintf("clone of repowarden (ref %s) impossible", ref)
	}
	suite := filepath.Join(dir, "repowarden", "test", "gitlab")
	if !exists(suite) {
		return 2, fmt.Sprintf("test/gitlab missing at ref %s", ref)
	}
	env := []string{"REPOWARDEN_IT_GITLAB_URL=" + s.api.base, "REPOWARDEN_IT_GITLAB_TOKEN=" + s.api.token}
	res, err = s.run("bats", []string{suite}, env...)
	if err != nil {
		return 1, "bats not found"
	}
	log := filepath.Join(os.TempDir(), "devzone-test-gitlab-repowarden.log")
	output := s.masked(string(res.Stdout) + string(res.Stderr))
	if err := os.WriteFile(log, []byte(output), 0o600); err != nil {
		return 1, "the test/gitlab suite log cannot be written"
	}
	if res.Code != 0 {
		return 1, fmt.Sprintf("the test/gitlab suite failed (log: %s)", log)
	}
	return 0, ""
}

// stepFull is the --complet step: disable the module, then check that no
// namespace, labelled pod, secret folder or hosts line remains.
func stepFull(s *session) (int, string) {
	leftovers := ""
	res, err := s.run(s.devzone, []string{"disable", "gitlab"})
	if err != nil || res.Code != 0 {
		leftovers += " disable failed;"
	}
	ns := "devzone-gitlab" + instanceSuffix()
	res, err = s.run("kubectl", []string{"--context", "devzone", "get", "namespace", ns})
	if err == nil && res.Code == 0 {
		leftovers += " namespace " + ns + ";"
	}
	instance := os.Getenv("DEVZONE_INSTANCE")
	if instance == "" {
		instance = "devzone"
	}
	res, err = s.run("kubectl", []string{"--context", "devzone", "get", "pods", "--all-namespaces",
		"-l", "devzone.instance=" + instance, "-o", "name"})
	if err == nil && strings.TrimSpace(string(res.Stdout)) != "" {
		leftovers += " labelled container(s) devzone.instance=" + instance + ";"
	}
	secrets := filepath.Join(s.root, "workspace", ".gitlab")
	if exists(secrets) {
		leftovers += " " + secrets + ";"
	}
	data, _ := os.ReadFile(s.hosts)
	if strings.Contains(string(data), "# devzone:gitlab") {
		leftovers += " /etc/hosts line;"
	}
	if leftovers != "" {
		return 1, "remaining:" + leftovers
	}
	return 0, ""
}

// instanceSuffix returns the suffix of the instance namespace, empty for the
// default instance, as cluster.sh did for INSTANCE_SUFFIX.
func instanceSuffix() string {
	instance := os.Getenv("DEVZONE_INSTANCE")
	if instance == "" || instance == "devzone" {
		return ""
	}
	return "-" + instance
}

// exists reports whether a path is present on the filesystem.
func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
