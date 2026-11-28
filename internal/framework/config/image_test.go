package config

import "testing"

// TestImageRepoDefault keeps the published repository when no override is set.
func TestImageRepoDefault(t *testing.T) {
	t.Setenv("DEVZONE_IMAGE_REPO", "")
	if got := ImageRepo(); got != "ghcr.io/simbienvenuehoulboumi/devzone-workspace" {
		t.Fatalf("default image repository = %q", got)
	}
}

// TestImageRepoOverride checks that DEVZONE_IMAGE_REPO replaces the repository.
func TestImageRepoOverride(t *testing.T) {
	const override = "registry.example.test/team/workspace"
	t.Setenv("DEVZONE_IMAGE_REPO", override)
	if got := ImageRepo(); got != override {
		t.Fatalf("overridden image repository = %q, want %q", got, override)
	}
}
