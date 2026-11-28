// Package e2e runs the end-to-end test of the GitLab module and platform in
// Go (#866). It replays the steps of the former shell script with the runner of
// the framework, so that no real cluster, command or network is needed in the
// tests. A token is never written to an argument, a clone or a message.
package e2e

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Options carries the collaborators and the settings of one test run.
type Options struct {
	Runner    exec.Runner
	Out       io.Writer
	Err       io.Writer
	Root      string // devzone root, never the current folder
	Home      string // home of the glab binary and configuration
	State     string // state file holding the platform to restore
	Hosts     string // hosts file to inspect in step 8
	URL       string // GitLab base URL of the API calls
	Ref       string // ref of the repowarden integration suite
	Full      bool   // --complet: disable then reinstall
	Publish   bool   // --statut: publish the GitHub status
	Timeout   int    // pipeline timeout in seconds
	Interval  int    // pipeline polling interval in seconds
	Now       func() time.Time
	Sleep     func(time.Duration)
	MkdirTemp func(string) (string, error)
}

// session holds the state shared by the steps and the cleanup of one run.
type session struct {
	ctx       context.Context
	opts      Options
	root      string
	home      string
	state     string
	hosts     string
	devzone   string
	glab      string
	api       *apiClient
	token     string
	keyID     string
	platform  string
	urlBefore string
	changed   bool
	timeout   int
	interval  int
	current   string
	tempDirs  []string
	now       func() time.Time
	sleep     func(time.Duration)
	mkdirTemp func(string) (string, error)
}

// newSession resolves the defaults of the options as the shell script did.
func newSession(opts Options) *session {
	s := &session{opts: opts, now: opts.Now, sleep: opts.Sleep, mkdirTemp: opts.MkdirTemp}
	if s.now == nil {
		s.now = time.Now
	}
	if s.sleep == nil {
		s.sleep = time.Sleep
	}
	if s.mkdirTemp == nil {
		s.mkdirTemp = func(pattern string) (string, error) { return os.MkdirTemp("", pattern) }
	}
	s.root = opts.Root
	if s.root == "" {
		s.root = os.Getenv("DEVZONE_ROOT")
	}
	s.home = opts.Home
	if s.home == "" {
		s.home, _ = os.UserHomeDir()
	}
	s.state = opts.State
	if s.state == "" {
		s.state = os.Getenv("DEVZONE_STATE")
	}
	if s.state == "" {
		s.state = filepath.Join(s.root, ".devzone.modules")
	}
	s.hosts = opts.Hosts
	if s.hosts == "" {
		s.hosts = os.Getenv("DEVZONE_HOSTS")
	}
	if s.hosts == "" {
		s.hosts = "/etc/hosts"
	}
	s.devzone = os.Getenv("DEVZONE_TEST_DEVZONE")
	if s.devzone == "" {
		s.devzone = "devzone"
	}
	s.glab = filepath.Join(s.home, ".local", "bin", "glab")
	base := opts.URL
	if base == "" {
		base = os.Getenv("GITLAB_TEST_URL")
	}
	if base == "" {
		base = config.GitLab().WebURL()
	}
	s.api = &apiClient{base: base, client: &httpClient}
	s.timeout, s.interval = opts.Timeout, opts.Interval
	if s.timeout == 0 {
		s.timeout = secondsEnv("GITLAB_TEST_PIPELINE", 600)
	}
	if s.interval == 0 {
		s.interval = secondsEnv("GITLAB_TEST_INTERVALLE", 5)
	}
	s.platform, s.urlBefore = readPlatform(s.state)
	return s
}

// readPlatform returns the previous platform and its URL from the state file,
// as the trap of the shell script did before any step changed them.
func readPlatform(path string) (string, string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "github", ""
	}
	platform, url := "github", ""
	for _, line := range stringLines(string(data)) {
		if value, ok := cutPrefix(line, "platform="); ok {
			platform = value
		}
		if value, ok := cutPrefix(line, "gitlab_url="); ok {
			url = value
		}
	}
	if platform != "gitlab" {
		platform = "github"
	}
	return platform, url
}

// secondsEnv reads a positive number of seconds from the environment, with
// the shell default when it is missing or invalid.
func secondsEnv(name string, fallback int) int {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}
