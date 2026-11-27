package workspace

import (
	"os"
	"path/filepath"
	"testing"
)

// TestPortsAgentDirInjectable checks the folder of the definition on each
// platform and the override used by the tests. The folders are injected, so
// this stays valid on every platform.
func TestPortsAgentDirInjectable(t *testing.T) {
	home := t.TempDir()
	xdg := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", xdg)
	t.Setenv(portsAgentDirEnv, "")
	old := portsPlatform
	t.Cleanup(func() { portsPlatform = old })
	portsPlatform = "darwin"
	if got, want := portsAgentDir(), filepath.Join(home, "Library", "LaunchAgents"); got != want {
		t.Fatalf("darwin dir = %q, want %q", got, want)
	}
	portsPlatform = "linux"
	if got, want := portsAgentDir(), filepath.Join(xdg, "systemd", "user"); got != want {
		t.Fatalf("linux dir = %q, want %q", got, want)
	}
	t.Setenv(portsAgentDirEnv, filepath.Join(t.TempDir(), "agents"))
	if got := portsAgentDir(); got != os.Getenv(portsAgentDirEnv) {
		t.Fatalf("override = %q, want %q", got, os.Getenv(portsAgentDirEnv))
	}
}

// TestPortsWatcherBinDirUsesStableFolder checks that the watcher copy does not
// live in a temporary folder and can be redirected by XDG_CACHE_HOME. The
// platform is pinned so the expected name does not depend on the host: Windows
// adds the .exe extension, the other platforms do not.
func TestPortsWatcherBinDirUsesStableFolder(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	old := portsPlatform
	t.Cleanup(func() { portsPlatform = old })
	cases := []struct{ platform, name string }{
		{"linux", "devzone"},
		{"windows", "devzone.exe"},
	}
	for _, c := range cases {
		portsPlatform = c.platform
		want := filepath.Join(cache, "devzone", "ports", "bin", c.name)
		if got := portsWatcherCopyPath(); got != want {
			t.Fatalf("%s copy = %q, want %q", c.platform, got, want)
		}
	}
}
