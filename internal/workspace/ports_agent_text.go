package workspace

import (
	"os"
	"path"
	"path/filepath"
	"strings"
)

// portsAgentPath is the PATH given to the watcher by its automatic start, so
// that it finds the kubectl of the workstation even without the PATH of a
// terminal.
const portsAgentPath = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

// portsAgentWrite writes the definition of the automatic start of one devzone
// instance in dir, and returns its path. label is the full name of the agent or
// unit without its extension. Writing the same instance twice replaces the
// definition, so enable is idempotent.
//
// On Windows the file is the XML of the scheduled task, written in UTF-16 as its
// declaration says; the PATH and KUBECONFIG of env have no place in a task and
// are not written there.
func portsAgentWrite(dir, label, watcher, folder string, env portsAgentValues) (string, error) {
	name := label + "." + portsAgentExt()
	var data []byte
	switch portsPlatform {
	case "darwin":
		data = []byte(portsAgentPlistText(label, watcher, folder, env))
	case "windows":
		data = portsUTF16(portsAgentTaskText(watcher, folder))
	default:
		data = []byte(portsAgentUnitText(label, watcher, folder, env))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", err
	}
	return path, os.Chmod(path, 0o644)
}

// portsAgentRemove removes the definition named label from dir. A missing
// definition is not an error, so disable can be repeated.
func portsAgentRemove(dir, label string) error {
	name := label + "." + portsAgentExt()
	err := os.Remove(filepath.Join(dir, name))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// portsAgentPlistText returns the launch agent of the watcher. RunAtLoad starts
// it at login, and KeepAlive relaunches it only after an abnormal exit, so a
// watcher stopped on purpose stays stopped until the next start or session.
// The state folder uses "/" even when the binary was built on Windows: launchd
// reads slash paths.
func portsAgentPlistText(name, watcher, folder string, env portsAgentValues) string {
	kubeConfig := ""
	if env.kubeConfig != "" {
		kubeConfig = "\t\t<key>KUBECONFIG</key>\n\t\t<string>" + xmlEscape(env.kubeConfig) + "</string>\n"
	}
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
		"<plist version=\"1.0\">\n<dict>\n" +
		"\t<key>Label</key>\n\t<string>" + xmlEscape(name) + "</string>\n" +
		"\t<key>ProgramArguments</key>\n\t<array>\n" +
		"\t\t<string>" + xmlEscape(watcher) + "</string>\n" +
		"\t\t<string>workspace</string>\n\t\t<string>ports</string>\n\t\t<string>agent</string>\n" +
		"\t</array>\n" +
		"\t<key>WorkingDirectory</key>\n\t<string>" + xmlEscape(folder) + "</string>\n" +
		"\t<key>EnvironmentVariables</key>\n\t<dict>\n" +
		"\t\t<key>DEVZONE_PORTS_WORKSPACE_DIR</key>\n" +
		"\t\t<string>" + xmlEscape(path.Join(folder, portsStateName)) + "</string>\n" +
		"\t\t<key>PATH</key>\n\t\t<string>" + xmlEscape(env.path) + "</string>\n" +
		kubeConfig +
		"\t</dict>\n" +
		"\t<key>RunAtLoad</key>\n\t<true/>\n" +
		"\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n" +
		"</dict>\n</plist>\n"
}

// portsAgentUnitText returns the systemd user unit of the watcher. It runs in
// the devzone folder and is relaunched only after an abnormal exit. The state
// folder uses "/" even when the binary was built on Windows: systemd reads
// slash paths.
func portsAgentUnitText(name, watcher, folder string, env portsAgentValues) string {
	kubeConfig := ""
	if env.kubeConfig != "" {
		kubeConfig = "Environment=" + systemdQuote("KUBECONFIG="+env.kubeConfig) + "\n"
	}
	return "[Unit]\n" +
		"Description=devzone port watcher " + name + "\n" +
		"After=network-online.target\n" +
		"\n" +
		"[Service]\n" +
		"Type=simple\n" +
		"ExecStart=" + systemdQuote(watcher) + " workspace ports agent\n" +
		"WorkingDirectory=" + systemdPercent(folder) + "\n" +
		"Environment=" + systemdQuote("DEVZONE_PORTS_WORKSPACE_DIR="+path.Join(folder, portsStateName)) + "\n" +
		"Environment=" + systemdQuote("PATH="+env.path) + "\n" +
		kubeConfig +
		"Restart=on-failure\n" +
		"\n" +
		"[Install]\n" +
		"WantedBy=default.target\n"
}

// xmlEscape escapes the characters that XML needs escaped in a plist value.
func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&apos;").Replace(s)
}

// systemdPercent doubles the percent signs that systemd would read as
// specifiers, leaving a literal % in the unit.
func systemdPercent(s string) string {
	return strings.ReplaceAll(s, "%", "%%")
}

// systemdQuote writes a value in the syntax of systemd settings: double quotes
// keep spaces inside one argument, and a literal quote or backslash stays
// escaped. Percent signs are doubled as systemd requires in every setting.
func systemdQuote(s string) string {
	quoted := strings.ReplaceAll(systemdPercent(s), `\`, `\\`)
	quoted = strings.ReplaceAll(quoted, `"`, `\"`)
	return `"` + quoted + `"`
}
