// Package packages keeps the list of system packages surviving a pod rebuild.
// It replaces .devcontainer/packages.sh (#881). The installation tool is an
// injected Installer, so tests never install anything on the machine.
package packages

import (
	"context"
	"errors"
	"os"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Installer is the injected system-package tool used by the commands.
type Installer interface {
	Installed(name string) bool
	Available(name string) bool
	Update() error
	Install(names []string) error
	Remove(names []string) error
}

// SystemInstaller drives dpkg-query, apt-cache and apt-get through a Runner.
type SystemInstaller struct {
	Runner    fexec.Runner
	Sudo      string
	Apt       string
	AptCache  string
	DpkgQuery string
}

var _ Installer = (*SystemInstaller)(nil)

// SystemFromEnvironment builds the real installer from the overridable
// variables of the former shell library. An unset SUDO means "sudo"; an empty
// one means no elevation.
func SystemFromEnvironment(runner fexec.Runner) *SystemInstaller {
	sudo, set := os.LookupEnv("DEVZONE_PACKAGES_SUDO")
	if !set {
		sudo = "sudo"
	}
	return &SystemInstaller{
		Runner:    runner,
		Sudo:      sudo,
		Apt:       envOr("DEVZONE_PACKAGES_APT", "apt-get"),
		AptCache:  envOr("DEVZONE_PACKAGES_APTCACHE", "apt-cache"),
		DpkgQuery: envOr("DEVZONE_PACKAGES_DPKG_QUERY", "dpkg-query"),
	}
}

// envOr returns the value of key, or fallback when unset or empty.
func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// Installed reports whether dpkg-query sees a fully installed package.
func (s *SystemInstaller) Installed(name string) bool {
	if s.Runner == nil {
		return false
	}
	res, err := s.Runner.Run(context.Background(), s.DpkgQuery,
		[]string{"-W", "-f=${Status}", name}, fexec.Opts{})
	return err == nil && strings.Contains(string(res.Stdout), "install ok installed")
}

// Available reports whether apt-cache knows the package.
func (s *SystemInstaller) Available(name string) bool {
	if s.Runner == nil {
		return false
	}
	res, err := s.Runner.Run(context.Background(), s.AptCache, []string{"show", name}, fexec.Opts{})
	return err == nil && res.Code == 0
}

// Update refreshes the package index as root.
func (s *SystemInstaller) Update() error {
	return s.asRoot(false, s.Apt, "update")
}

// Install adds the packages as root without interactive prompts.
func (s *SystemInstaller) Install(names []string) error {
	args := append([]string{"install", "-y", "--no-install-recommends"}, names...)
	return s.asRoot(true, s.Apt, args...)
}

// Remove deletes the packages as root.
func (s *SystemInstaller) Remove(names []string) error {
	args := append([]string{"remove", "-y"}, names...)
	return s.asRoot(false, s.Apt, args...)
}

// asRoot runs a program through sudo, or directly when no elevation is set.
func (s *SystemInstaller) asRoot(nonInteractive bool, program string, args ...string) error {
	if s.Runner == nil {
		return errors.New("no package runner")
	}
	opts := fexec.Opts{}
	name := program
	if s.Sudo != "" {
		name = s.Sudo
		if nonInteractive {
			args = append([]string{"DEBIAN_FRONTEND=noninteractive", program}, args...)
		} else {
			args = append([]string{program}, args...)
		}
	} else if nonInteractive {
		opts.Env = []string{"DEBIAN_FRONTEND=noninteractive"}
	}
	res, err := s.Runner.Run(context.Background(), name, args, opts)
	if err != nil || res.Code != 0 {
		return errors.New("system package command failed")
	}
	return nil
}
