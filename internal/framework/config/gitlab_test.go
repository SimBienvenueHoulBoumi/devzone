package config

import "testing"

// TestGitLabDefaults keeps the shipped host and ports when no override is set.
func TestGitLabDefaults(t *testing.T) {
	t.Setenv("DEVZONE_GITLAB_URL", "")
	gitlab := GitLab()
	if gitlab.Host != "gitlab.localhost" || gitlab.WebPort != "8929" || gitlab.SSHPort != "2224" {
		t.Fatalf("default GitLab endpoint = %+v", gitlab)
	}
	if got := gitlab.WebURL(); got != "http://gitlab.localhost:8929" {
		t.Fatalf("default GitLab web URL = %q", got)
	}
	if got := gitlab.SSHHostPort(); got != "gitlab.localhost:2224" {
		t.Fatalf("default GitLab SSH address = %q", got)
	}
}

// TestGitLabOverride checks that DEVZONE_GITLAB_URL replaces the host, the web
// port and, through its ssh parameter, the SSH port.
func TestGitLabOverride(t *testing.T) {
	t.Setenv("DEVZONE_GITLAB_URL", "https://gitlab.example.test:9443?ssh=2225")
	gitlab := GitLab()
	if gitlab.Host != "gitlab.example.test" || gitlab.WebPort != "9443" || gitlab.SSHPort != "2225" {
		t.Fatalf("overridden GitLab endpoint = %+v", gitlab)
	}
	if got := gitlab.WebURL(); got != "https://gitlab.example.test:9443" {
		t.Fatalf("overridden GitLab web URL = %q", got)
	}
	if got := gitlab.SSHHostPort(); got != "gitlab.example.test:2225" {
		t.Fatalf("overridden GitLab SSH address = %q", got)
	}
}

// TestGitLabInvalidOverride keeps the defaults when the variable is unusable.
func TestGitLabInvalidOverride(t *testing.T) {
	t.Setenv("DEVZONE_GITLAB_URL", "gitlab.example.test:9443")
	if got := GitLab().WebURL(); got != "http://gitlab.localhost:8929" {
		t.Fatalf("web URL with an invalid override = %q", got)
	}
}
