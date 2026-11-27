package command

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestVolumeNameFromMount checks the mounts read by the shell's node script: a
// string or an object, volume type only, the name being the source.
func TestVolumeNameFromMount(t *testing.T) {
	cases := []struct {
		raw, want string
	}{
		{`"source=devzone-m2,target=/x,type=volume"`, "devzone-m2"},
		{`"source=devzone-gh,type=volume"`, "devzone-gh"},
		{`"source=/host,target=/x,type=bind"`, ""},
		{`{"source":"devzone-agent","target":"/y","type":"volume"}`, "devzone-agent"},
		{`{"source":"/host","target":"/y","type":"bind"}`, ""},
		// No source: the shell template gave "undefined", which no volume has
		{`{"target":"/y","type":"volume"}`, "undefined"},
		{`42`, ""},
	}
	for _, c := range cases {
		if got := volumeName(mountSpec(json.RawMessage(c.raw))); got != c.want {
			t.Errorf("mount %s: name = %q, want %q", c.raw, got, c.want)
		}
	}
}

// TestKeepsLoginsRule checks which volumes KEEP=logins keeps: the logins suffixes
// only, and nothing when KEEP is not logins or connexions.
func TestKeepsLoginsRule(t *testing.T) {
	cases := []struct {
		keep, volume string
		want         bool
	}{
		{"logins", "devzone-gh", true},
		{"connexions", "mon-claude", true},
		{"logins", "devzone-opencode-config", true},
		{"logins", "devzone-m2", false},
		{"logins", "devzone-ghx", false},
		{"", "devzone-gh", false},
	}
	for _, c := range cases {
		if got := keepsLogins(c.keep, c.volume); got != c.want {
			t.Errorf("keepsLogins(%q, %q) = %v, want %v", c.keep, c.volume, got, c.want)
		}
	}
}

// TestUninstallKeepValues checks the KEEP value: GARDER is the fallback, and
// any other value is refused.
func TestUninstallKeepValues(t *testing.T) {
	t.Setenv("KEEP", "")
	t.Setenv("GARDER", "connexions")
	if got, err := uninstallKeep(); err != nil || got != "connexions" {
		t.Fatalf("GARDER: got %q, %v", got, err)
	}
	t.Setenv("KEEP", "logins")
	if got, err := uninstallKeep(); err != nil || got != "logins" {
		t.Fatalf("KEEP: got %q, %v", got, err)
	}
	t.Setenv("KEEP", "bogus")
	if _, err := uninstallKeep(); err == nil || err.Error() != "KEEP: unknown value: bogus (only value: logins)" {
		t.Fatalf("bogus: err = %v", err)
	}
}

// TestNetworkEmptyRule checks the kind network removal guard: only a network
// whose every inspection lists no container counts as empty.
func TestNetworkEmptyRule(t *testing.T) {
	cases := []struct {
		doc  string
		want bool
	}{
		{`[{"Containers": {}}]`, true},
		{`[{"Containers": {"abc": {}}}]`, false},
		{`[]`, false},
		{`not json`, false},
		{``, false},
	}
	for _, c := range cases {
		if got := networkEmpty([]byte(c.doc)); got != c.want {
			t.Errorf("networkEmpty(%s) = %v, want %v", c.doc, got, c.want)
		}
	}
}

// TestStateImageAndDindFirstMatch reads IMAGE and DIND of the state file, the
// first line of each, and nothing from a missing file.
func TestStateImageAndDindFirstMatch(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".devzone.state")
	if err := os.WriteFile(path, []byte("IMAGE=vsc-x:1\nother=1\nIMAGE=second\r\nDIND=dind-x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	image, dind := stateImageAndDind(path)
	if image != "vsc-x:1" || dind != "dind-x" {
		t.Fatalf("image = %q, dind = %q", image, dind)
	}
	if image, dind := stateImageAndDind(filepath.Join(t.TempDir(), "absent")); image != "" || dind != "" {
		t.Fatalf("absent file: %q, %q", image, dind)
	}
}

// TestMetricsManifestFromVersions checks that the manifest is the one of the
// version pinned in versions.env.
func TestMetricsManifestFromVersions(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".devcontainer", "versions.env"), []byte("X=1\nMETRICS_SERVER_VERSION=v0.9.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	want := "https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml"
	if got := metricsManifestURL(root); got != want {
		t.Fatalf("manifest = %q", got)
	}
}

// TestDevzoneMarkValues checks the two spellings of the devzone label.
func TestDevzoneMarkValues(t *testing.T) {
	for mark, want := range map[string]bool{"installe": true, "installed": true, "": false, "other": false} {
		if got := isDevzoneMark(mark); got != want {
			t.Errorf("isDevzoneMark(%q) = %v, want %v", mark, got, want)
		}
	}
}

// TestWithoutKeepsOrder checks the removal of resources already listed
// elsewhere: the others keep their order, so the shell's order is kept.
func TestWithoutKeepsOrder(t *testing.T) {
	got := without([]string{"c", "a", "b", "a"}, []string{"b"}, []string{"c"})
	if len(got) != 2 || got[0] != "a" || got[1] != "a" {
		t.Fatalf("without = %v", got)
	}
}

// TestConfirmedByCONFIRMER checks the French name of the confirmation variable.
func TestConfirmedByCONFIRMER(t *testing.T) {
	t.Setenv("CONFIRM", "")
	t.Setenv("CONFIRMER", "yes")
	if !confirmedByEnv() {
		t.Fatal("CONFIRMER=yes not accepted")
	}
	t.Setenv("CONFIRM", "no")
	if confirmedByEnv() {
		t.Fatal("CONFIRM=no accepted")
	}
}

// TestParseUninstallArgsRefusesUnknown checks the options: --yes only.
func TestParseUninstallArgsRefusesUnknown(t *testing.T) {
	if yes, bad := parseUninstallArgs([]string{"--yes"}); !yes || bad != "" {
		t.Fatalf("--yes: %v %q", yes, bad)
	}
	if _, bad := parseUninstallArgs([]string{"--bogus"}); bad != "✖ unknown option: --bogus (devzone uninstall [--yes])" {
		t.Fatalf("--bogus: %q", bad)
	}
}

// TestEngineCommandAndNameFromEnvironment checks the engine command name (the
// override DEVZONE_DOCKER, used by the tests and the CI) and the command name
// the host check asks to run again (DEVZONE_COMMAND, else devzone uninstall).
func TestEngineCommandAndNameFromEnvironment(t *testing.T) {
	t.Setenv("DEVZONE_DOCKER", "")
	t.Setenv("DEVZONE_COMMAND", "")
	if got := engineCommand(); got != "docker" {
		t.Fatalf("engineCommand = %q, want docker", got)
	}
	if got := uninstallCommandName(); got != "devzone uninstall" {
		t.Fatalf("uninstallCommandName = %q", got)
	}
	t.Setenv("DEVZONE_DOCKER", "engine-test")
	t.Setenv("DEVZONE_COMMAND", "make desinstaller")
	if engineCommand() != "engine-test" || uninstallCommandName() != "make desinstaller" {
		t.Fatal("environment overrides not read")
	}
}
