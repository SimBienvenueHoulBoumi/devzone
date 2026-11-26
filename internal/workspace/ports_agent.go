package workspace

import (
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// portsPlatform is the platform of the automatic start: runtime.GOOS in the
// program, replaceable in tests so that both definitions can be checked on any
// machine. No test calls the real launchctl or systemctl.
var portsPlatform = runtime.GOOS

// PortsPlatform returns the platform used to choose the automatic start of the
// port watcher, so a caller on the workstation uses the same injectable value
// as the watcher itself instead of reading the build platform again.
func PortsPlatform() string {
	return portsPlatform
}

// portsAgentDirEnv names the environment variable that overrides the folder of
// the automatic start of the port watcher, so that tests use a temporary folder.
const portsAgentDirEnv = "DEVZONE_PORTS_AGENT_DIR"

// portsAgentPrefix is the prefix of the name of the automatic start file, per
// devzone instance.
const portsAgentPrefix = "devzone-ports-workspace-"

// portsAgentExt returns the extension of the automatic start file: the launch
// agent of macOS, the user unit of Linux.
func portsAgentExt() string {
	if portsPlatform == "darwin" {
		return "plist"
	}
	return "service"
}

// portsAgentDir returns the folder holding the automatic start of this devzone
// instance: the override, else the personal folder of the platform.
func portsAgentDir() string {
	if dir := os.Getenv(portsAgentDirEnv); dir != "" {
		return dir
	}
	if portsPlatform == "darwin" {
		if home := homeDir(); home != "" {
			return filepath.Join(home, "Library", "LaunchAgents")
		}
	}
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "systemd", "user")
	}
	if home := homeDir(); home != "" {
		return filepath.Join(home, ".config", "systemd", "user")
	}
	return filepath.Join("systemd", "user")
}

// portsInstance returns the instance of this devzone folder: DEVZONE_INSTANCE,
// then DEVZONE_VOLUMES, then "devzone".
func portsInstance() string {
	for _, key := range []string{"DEVZONE_INSTANCE", "DEVZONE_VOLUMES"} {
		if value := os.Getenv(key); value != "" {
			return value
		}
	}
	return "devzone"
}

// portsAgentName returns the name of the automatic start file of this folder.
// It hashes the absolute devzone folder so two folders of the same instance
// never share one definition.
func portsAgentName() string {
	return portsAgentNameFor(portsInstance(), portsDevzoneFolder())
}

// portsNameFingerprint returns an eight-digit hexadecimal fingerprint of s.
// FNV-1a keeps definition names distinct per folder without linking a
// cryptographic hash into the binary, which nothing else in cmd/devzone uses.
func portsNameFingerprint(s string) string {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return fmt.Sprintf("%08x", h.Sum32())
}

// portsAgentNameFor returns the definition name of instance in folder, with the
// same sanitising and hashes as enable, so disable finds the file enable wrote
// even when the instance name contains characters that had to be replaced.
func portsAgentNameFor(instance, folder string) string {
	safe := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
			return r
		}
		return '-'
	}, instance)
	if safe != instance {
		safe += "-" + portsNameFingerprint(instance)
	}
	absolute, err := filepath.Abs(folder)
	if err != nil {
		absolute = folder
	}
	return portsAgentPrefix + safe + "-" + portsNameFingerprint(absolute)
}

// portsAgentExists tells whether the automatic start of the port watcher is
// installed for this devzone instance.
func portsAgentExists() bool {
	path := filepath.Join(portsAgentDir(), portsAgentName()+"."+portsAgentExt())
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// portsWatcherBinDir returns the stable folder of the user holding the copy of
// the watcher binary; XDG_CACHE_HOME and HOME make it injectable in tests.
func portsWatcherBinDir() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		base = filepath.Join(homeDir(), ".cache")
	}
	return filepath.Join(base, "devzone", "ports", "bin")
}

// portsWatcherCopyPath returns the path of the watcher binary used by the
// automatic start, in the stable folder of the user.
func portsWatcherCopyPath() string {
	return filepath.Join(portsWatcherBinDir(), "devzone")
}

// homeDir returns the personal folder of the user, or an empty string when it
// cannot be read.
func homeDir() string {
	if home := os.Getenv("HOME"); home != "" {
		return home
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return home
}
