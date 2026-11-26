package gitlab

import (
	"os"
	"strings"
	"testing"
)

// TestInstallDoesNotSwitchWorkingContext checks that installing GitLab in the
// services cluster never creates a kind cluster nor switches the working
// context (gitlab.bats, gitlab-rebuild.bats).
func TestInstallDoesNotSwitchWorkingContext(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	for _, forbidden := range []string{"config use-context", "config unset current-context",
		"create cluster", "export kubeconfig"} {
		for _, call := range f.calls() {
			if strings.Contains(call, forbidden) {
				t.Errorf("%q called: %s", forbidden, call)
			}
		}
	}
	if !f.hasCall("--namespace devzone-gitlab") {
		t.Errorf("no install in the instance namespace: %v", f.calls())
	}
}

// TestInstallValuesSSHAndChartPins checks the wrapper chart values: SSH clone
// on 2224, ClusterIP services, ingress off, host without port and external
// port through GITLAB_PORT (gitlab.bats).
func TestInstallValuesSSHAndChartPins(t *testing.T) {
	data, err := os.ReadFile("../../../charts/devzone-gitlab/values.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"port: 2224", "type: ClusterIP", "nginx-ingress:",
		`GITLAB_PORT: "8929"`, "name: gitlab.localhost"} {
		if !strings.Contains(string(data), want) {
			t.Errorf("values.yaml lacks %q", want)
		}
	}
	for _, gone := range []string{"NodePort", "LoadBalancer", "hostPort",
		"hostnameOverride", "gitlab-shell: 2224"} {
		if strings.Contains(string(data), gone) {
			t.Errorf("values.yaml has %q", gone)
		}
	}
	if _, err := os.Stat("../../../.devcontainer/gitlab/kind.yaml"); !os.IsNotExist(err) {
		t.Errorf("kind.yaml still present: %v", err)
	}
}

// TestInstallNetworkPolicyApplied checks that the namespace is labelled and
// isolated by the NetworkPolicy of the instance (gitlab-cluster.bats).
func TestInstallNetworkPolicyApplied(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d", code)
	}
	if !f.hasCall("label namespace devzone-gitlab app.kubernetes.io/managed-by=devzone") {
		t.Errorf("namespace not labelled: %v", f.calls())
	}
	policy := ""
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && call.Opts.Stdin != nil {
			buf := make([]byte, 4096)
			n, _ := call.Opts.Stdin.Read(buf)
			policy += string(buf[:n])
		}
	}
	for _, want := range []string{"kind: NetworkPolicy", "devzone-meme-namespace"} {
		if !strings.Contains(policy, want) {
			t.Errorf("network policy lacks %q: %s", want, policy)
		}
	}
}

// TestInstallHostLineSetAndUninstallRemoves checks the /etc/hosts line across
// an install and an uninstall (gitlab.bats).
func TestInstallHostLineSetAndUninstallRemoves(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile("hosts", "127.0.0.1 localhost\n")
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d", code)
	}
	if !strings.Contains(f.readFile("hosts"), "127.0.0.1\tgitlab.localhost # devzone:gitlab") {
		t.Errorf("hosts = %q", f.readFile("hosts"))
	}
	if code := f.run("uninstall"); code != 0 {
		t.Fatalf("uninstall: code = %d", code)
	}
	if strings.Contains(f.readFile("hosts"), "devzone:gitlab") ||
		!strings.Contains(f.readFile("hosts"), "127.0.0.1 localhost") {
		t.Errorf("hosts after uninstall = %q", f.readFile("hosts"))
	}
}

// TestInstallMemoryRefusalNothingStarted checks that under 8 GiB nothing is
// started and the working context is kept (gitlab-rebuild.bats).
func TestInstallMemoryRefusalNothingStarted(t *testing.T) {
	f := newFixture(t)
	f.programCurrentContext("devzone-services")
	f.programMemory("4000000Ki\n")
	if code := f.run("install"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "at least 8 GiB") {
		t.Errorf("stderr = %q", f.errStr())
	}
	for _, call := range f.calls() {
		if strings.HasPrefix(call, "helm ") || strings.HasPrefix(call, "kind ") ||
			strings.Contains(call, "config use-context") {
			t.Errorf("something started despite the refusal: %s", call)
		}
	}
}

// TestMemoryQuantityConversion checks the conversion of Kubernetes memory
// quantities, the basis of the refusal of the module.
func TestMemoryQuantityConversion(t *testing.T) {
	for input, want := range map[string]int64{
		"": 0, "abc": 0, "1024": 1, "1Ki": 1, "2Mi": 2048,
		"1Gi": 1048576, "1000K": 976, "1000000M": 976562500,
	} {
		if got := quantityKi(input); got != want {
			t.Errorf("quantityKi(%q) = %d, want %d", input, got, want)
		}
	}
}

// TestMigrateKeepsContextAndOrder checks that migrate --yes installs before
// deleting the old cluster and never switches the working context
// (gitlab-cluster.bats, gitlab-rebuild.bats).
func TestMigrateKeepsContextAndOrder(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.programKindClusters("gitlab\n")
	if code := f.run("migrate", "--yes"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	helm, kindDelete := -1, -1
	for i, call := range f.calls() {
		if strings.Contains(call, "upgrade --install gitlab") && helm < 0 {
			helm = i
		}
		if strings.Contains(call, "delete cluster --name gitlab") && kindDelete < 0 {
			kindDelete = i
		}
		if strings.Contains(call, "config use-context") {
			t.Errorf("working context switched: %s", call)
		}
	}
	if helm < 0 || kindDelete < 0 || helm > kindDelete {
		t.Errorf("install at %d, old cluster deletion at %d: %v", helm, kindDelete, f.calls())
	}
	if !f.hasCall("create secret generic gitlab-runner-secret") {
		t.Errorf("seed not redone by migrate: %v", f.calls())
	}
}

// TestStatusNoExposureWarning checks that the status never reports a node
// published on the local network (gitlab.bats).
func TestStatusNoExposureWarning(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(true)
	testBaseURL = failingServer(t).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(f.outStr(), "failed: devzone apply") ||
		strings.Contains(f.outStr(), "exposed to the local network") {
		t.Errorf("output = %q", f.outStr())
	}
}
