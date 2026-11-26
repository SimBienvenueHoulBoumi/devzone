package gitlab

import (
	"os"
	"strings"
	"testing"
)

// TestUninstallRemovesReleasesNamespaceAndSecrets checks that uninstall
// removes the releases, the namespace and the instance secrets (gitlab.bats
// "uninstall removes the releases, the namespace and the secrets").
func TestUninstallRemovesReleasesNamespaceAndSecrets(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	f.reset()
	if code := f.run("uninstall"); code != 0 {
		t.Fatalf("uninstall: code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("uninstall gitlab --namespace devzone-gitlab") {
		t.Errorf("no helm uninstall gitlab in calls: %v", f.calls())
	}
	if !f.hasCall("delete namespace devzone-gitlab --ignore-not-found") {
		t.Errorf("no delete namespace in calls: %v", f.calls())
	}
	if !strings.Contains(f.outStr(), "▶ Uninstalling GitLab…") || !strings.Contains(f.outStr(), "✔ GitLab uninstalled.") {
		t.Errorf("output = %q", f.outStr())
	}
	if _, err := os.Stat(f.secretsDir() + "/rails-secret.yaml"); err != nil {
		t.Errorf("rails-secret.yaml missing: %v", err)
	}
	for _, gone := range []string{"root-password", "root-token", "runner-token"} {
		if _, err := os.Stat(f.secretsDir() + "/" + gone); err == nil {
			t.Errorf("%s still there", gone)
		}
	}
	if _, err := os.Stat(f.root + "/hosts"); err != nil {
		t.Errorf("hosts file missing")
	}
}

// TestUninstallYesDeletesRailsSecret checks that uninstall --yes deletes the
// kept Rails secret with the GitLab data (gitlab-secrets.bats).
func TestUninstallYesDeletesRailsSecret(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d", code)
	}
	f.writeFile("workspace/.gitlab/rails-secret.yaml", "{\"kind\":\"Secret\"}\n")
	if code := f.run("uninstall", "--yes"); code != 0 {
		t.Fatalf("uninstall --yes: code = %d", code)
	}
	if _, err := os.Stat(f.secretsDir()); !os.IsNotExist(err) {
		t.Errorf("secrets dir still there: %v", err)
	}
	if !strings.Contains(f.outStr(), "Rails secret deleted") {
		t.Errorf("output = %q", f.outStr())
	}
}

// TestUninstallKeepsRailsSecretWithoutYes checks that uninstall keeps the
// Rails secret (gitlab-secrets.bats "uninstall keeps rails-secret.yaml").
func TestUninstallKeepsRailsSecretWithoutYes(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d", code)
	}
	f.writeFile("workspace/.gitlab/rails-secret.yaml", "{\"kind\":\"Secret\"}\n")
	if code := f.run("uninstall"); code != 0 {
		t.Fatalf("uninstall: code = %d", code)
	}
	if _, err := os.Stat(f.secretsDir() + "/rails-secret.yaml"); err != nil {
		t.Errorf("rails-secret.yaml missing")
	}
	if !strings.Contains(f.outStr(), "Rails secret kept in workspace/.gitlab/rails-secret.yaml") {
		t.Errorf("output = %q", f.outStr())
	}
}

// TestUninstallUnknownArgument checks the refusal of an unknown argument.
func TestUninstallUnknownArgument(t *testing.T) {
	f := newFixture(t)
	if code := f.run("uninstall", "--foo"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "devzone : gitlab uninstall : unknown argument : --foo") {
		t.Errorf("stderr = %q", f.errStr())
	}
}
