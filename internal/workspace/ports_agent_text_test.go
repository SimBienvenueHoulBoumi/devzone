package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testAgentEnv is a deterministic environment for the definition text tests:
// a kubectl folder after the fixed paths, and a kubeconfig of the user.
func testAgentEnv() portsAgentValues {
	return portsAgentValues{
		path:       portsAgentPath + string(os.PathListSeparator) + "/opt/kube bin",
		kubeConfig: "/home/me/My Kube%config",
	}
}

// TestPortsAgentPlistTextExact checks the whole launch agent, including the XML
// escaping of a devzone folder with spaces and XML characters.
func TestPortsAgentPlistTextExact(t *testing.T) {
	name := "devzone-ports-workspace-atlas"
	folder := "/Users/me/Dev & Ops' \"Zone\" <x>"
	watcher := folder + "/bin/devzone"
	got := portsAgentPlistText(name, watcher, folder, testAgentEnv())
	want := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
		"<plist version=\"1.0\">\n<dict>\n" +
		"\t<key>Label</key>\n\t<string>" + name + "</string>\n" +
		"\t<key>ProgramArguments</key>\n\t<array>\n" +
		"\t\t<string>/Users/me/Dev &amp; Ops&apos; &quot;Zone&quot; &lt;x&gt;/bin/devzone</string>\n" +
		"\t\t<string>workspace</string>\n\t\t<string>ports</string>\n\t\t<string>agent</string>\n" +
		"\t</array>\n" +
		"\t<key>WorkingDirectory</key>\n\t<string>/Users/me/Dev &amp; Ops&apos; &quot;Zone&quot; &lt;x&gt;</string>\n" +
		"\t<key>EnvironmentVariables</key>\n\t<dict>\n" +
		"\t\t<key>DEVZONE_PORTS_WORKSPACE_DIR</key>\n" +
		"\t\t<string>/Users/me/Dev &amp; Ops&apos; &quot;Zone&quot; &lt;x&gt;/.devzone.workspace-ports</string>\n" +
		"\t\t<key>PATH</key>\n\t\t<string>/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" + string(os.PathListSeparator) + "/opt/kube bin</string>\n" +
		"\t\t<key>KUBECONFIG</key>\n\t\t<string>/home/me/My Kube%config</string>\n" +
		"\t</dict>\n" +
		"\t<key>RunAtLoad</key>\n\t<true/>\n" +
		"\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n" +
		"</dict>\n</plist>\n"
	if got != want {
		t.Fatalf("plist =\n%s\nwant:\n%s", got, want)
	}
}

// TestPortsAgentUnitTextExact checks the whole systemd user unit, including the
// PATH and the KUBECONFIG taken from the user environment.
func TestPortsAgentUnitTextExact(t *testing.T) {
	name := "devzone-ports-workspace-atlas"
	folder := "/home/me/Dev Ops/100% $HOME & more"
	watcher := folder + "/bin/devzone"
	unitFolder := "/home/me/Dev Ops/100%% $HOME & more"
	separator := string(os.PathListSeparator)
	got := portsAgentUnitText(name, watcher, folder, testAgentEnv())
	want := "[Unit]\n" +
		"Description=devzone port watcher " + name + "\n" +
		"After=network-online.target\n\n" +
		"[Service]\nType=simple\n" +
		"ExecStart=\"" + unitFolder + "/bin/devzone\" workspace ports agent\n" +
		"WorkingDirectory=" + unitFolder + "\n" +
		"Environment=\"DEVZONE_PORTS_WORKSPACE_DIR=" + unitFolder + "/.devzone.workspace-ports\"\n" +
		"Environment=\"PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" + separator + "/opt/kube bin\"\n" +
		"Environment=\"KUBECONFIG=/home/me/My Kube%%config\"\n" +
		"Restart=on-failure\n\n" +
		"[Install]\nWantedBy=default.target\n"
	if got != want {
		t.Fatalf("unit =\n%s\nwant:\n%s", got, want)
	}
}

// TestPortsAgentWriteUsesPlatform writes the two definitions of one instance:
// the extension and the text follow the injected platform.
func TestPortsAgentWriteUsesPlatform(t *testing.T) {
	dir := t.TempDir()
	old := portsPlatform
	t.Cleanup(func() { portsPlatform = old })
	portsPlatform = "darwin"
	path, err := portsAgentWrite(dir, portsAgentPrefix+"atlas", "/tmp/watch", "/tmp/Dev Zone", testAgentEnv())
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "devzone-ports-workspace-atlas.plist"); path != want {
		t.Fatalf("path = %q, want %q", path, want)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != portsAgentPlistText("devzone-ports-workspace-atlas", "/tmp/watch", "/tmp/Dev Zone", testAgentEnv()) {
		t.Fatalf("plist content = %q", data)
	}
	portsPlatform = "linux"
	path, err = portsAgentWrite(dir, portsAgentPrefix+"atlas", "/tmp/watch", "/tmp/Dev Zone", testAgentEnv())
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "devzone-ports-workspace-atlas.service"); path != want {
		t.Fatalf("path = %q, want %q", path, want)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != portsAgentUnitText("devzone-ports-workspace-atlas", "/tmp/watch", "/tmp/Dev Zone", testAgentEnv()) {
		t.Fatalf("unit content = %q", data)
	}
}

// TestPortsAgentNameSeparatesInstances keeps two devzone folders with nearly
// equal names from writing over each other.
func TestPortsAgentNameSeparatesInstances(t *testing.T) {
	old := portsPlatform
	t.Cleanup(func() { portsPlatform = old })
	portsPlatform = "linux"
	t.Setenv("DEVZONE_INSTANCE", "team/a")
	t.Setenv("DEVZONE_VOLUMES", "")
	first := portsAgentName()
	t.Setenv("DEVZONE_INSTANCE", "team-a")
	second := portsAgentName()
	if first == second {
		t.Fatalf("both instances use %q", first)
	}
	t.Setenv("DEVZONE_INSTANCE", "alpha")
	if got := portsAgentName(); !strings.HasPrefix(got, portsAgentPrefix+"alpha-") {
		t.Fatalf("name = %q, want the instance and a folder hash", got)
	}
}
