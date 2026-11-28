package config

import (
	"net/url"
	"os"
)

const (
	// DefaultGitLabHost is the host of the GitLab instance of the services cluster.
	DefaultGitLabHost = "gitlab.localhost"
	// DefaultGitLabWebPort is the port of the GitLab web and API relay.
	DefaultGitLabWebPort = "8929"
	// DefaultGitLabSSHPort is the port of the GitLab SSH relay.
	DefaultGitLabSSHPort = "2224"
)

// GitLabEndpoint holds the host, the web port and the SSH port of one GitLab
// instance, with the scheme used to build its web URL.
type GitLabEndpoint struct {
	Host    string
	WebPort string
	SSHPort string
	scheme  string
}

// GitLab returns the GitLab endpoint, overridden as a whole by
// DEVZONE_GITLAB_URL: its host and port replace the web defaults, and an
// optional "ssh" query parameter replaces the SSH port.
func GitLab() GitLabEndpoint {
	endpoint := GitLabEndpoint{
		Host:    DefaultGitLabHost,
		WebPort: DefaultGitLabWebPort,
		SSHPort: DefaultGitLabSSHPort,
		scheme:  "http",
	}
	raw := os.Getenv("DEVZONE_GITLAB_URL")
	if raw == "" {
		return endpoint
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Hostname() == "" {
		return endpoint
	}
	endpoint.Host = parsed.Hostname()
	if port := parsed.Port(); port != "" {
		endpoint.WebPort = port
	}
	if port := parsed.Query().Get("ssh"); port != "" {
		endpoint.SSHPort = port
	}
	if parsed.Scheme != "" {
		endpoint.scheme = parsed.Scheme
	}
	return endpoint
}

// WebURL returns the base URL of the GitLab web and API endpoints.
func (g GitLabEndpoint) WebURL() string {
	return g.scheme + "://" + g.Host + ":" + g.WebPort
}

// SSHHostPort returns the host and port used by SSH clones of GitLab projects.
func (g GitLabEndpoint) SSHHostPort() string {
	return g.Host + ":" + g.SSHPort
}
