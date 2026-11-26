//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// TestPortsDarwinTargetsFollowLaunchctlSyntax checks the argument vectors of
// launchctl against its syntax: bootstrap <domain-target> <plist>, bootout
// <service-target>, the domain being gui/<uid> and the service gui/<uid>/<label>.
func TestPortsDarwinTargetsFollowLaunchctlSyntax(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "darwin"
	uid := strconv.Itoa(os.Getuid())
	label := portsAgentName()
	plist := filepath.Join(portsAgentDir(), label+".plist")

	if got, want := portsDaemonDomain(), "gui/"+uid; got != want {
		t.Fatalf("domain = %q, want %q", got, want)
	}
	if got, want := portsDaemonEnableArgs(plist), []string{"bootstrap", "gui/" + uid, plist}; !reflect.DeepEqual(got, want) {
		t.Fatalf("enable args = %v, want %v", got, want)
	}
	if got, want := portsDaemonDisableArgs(), []string{"bootout", "gui/" + uid + "/" + label}; !reflect.DeepEqual(got, want) {
		t.Fatalf("disable args = %v, want %v", got, want)
	}
	if got, want := portsDaemonStartArgs(), []string{"bootstrap", "gui/" + uid, plist}; !reflect.DeepEqual(got, want) {
		t.Fatalf("start args = %v, want %v", got, want)
	}

	writeFile(t, plist, "installed\n")
	h.calls = nil
	var out, errOut bytes.Buffer
	if code := PortsStart(&out, &errOut); code != 0 {
		t.Fatalf("start = %d, err = %q", code, errOut.String())
	}
	want := []string{"kickstart", "-k", "gui/" + uid + "/" + label}
	if len(h.calls) != 1 || !reflect.DeepEqual(h.calls[0].args, want) {
		t.Fatalf("daemon calls = %v, want one call %v", h.calls, want)
	}
}

// TestPortsPlistLabelIsTheServiceName checks that the Label of the launch agent
// is the name the service target is built from, so launchctl finds the job.
func TestPortsPlistLabelIsTheServiceName(t *testing.T) {
	_ = newPortsEnableHarness(t)
	portsPlatform = "darwin"
	name := portsAgentName()
	plist := portsAgentPlistText(name, "/bin/devzone", "/work/zone", portsAgentValues{path: portsAgentPath})
	if !strings.Contains(plist, "<key>Label</key>\n\t<string>"+name+"</string>") {
		t.Fatalf("plist label does not match %q:\n%s", name, plist)
	}
	if !strings.HasSuffix(portsDaemonDomain()+"/"+name, "/"+name) || !strings.HasPrefix(portsDaemonDomain()+"/"+name, "gui/") {
		t.Fatalf("service target = %q", portsDaemonDomain()+"/"+name)
	}
}
