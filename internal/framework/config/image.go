// Package config holds the installation defaults shared by the commands, with
// their environment overrides, so no value is written twice in the code.
package config

import "os"

// DefaultImageRepo is the published workspace image repository.
const DefaultImageRepo = "ghcr.io/simbienvenuehoulboumi/devzone-workspace"

// ImageRepo returns the workspace image repository, overridden by
// DEVZONE_IMAGE_REPO when that variable is set.
func ImageRepo() string {
	if repo := os.Getenv("DEVZONE_IMAGE_REPO"); repo != "" {
		return repo
	}
	return DefaultImageRepo
}
