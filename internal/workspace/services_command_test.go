package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestHelmDeployArgs checks the helm call of a direct deployment: the devzone
// context, the image tag and the egress parameters with escaped commas.
func TestHelmDeployArgs(t *testing.T) {
	modules := filepath.Join(t.TempDir(), ".devzone.modules")
	if err := os.WriteFile(modules, []byte("egress=strict\negress_domains=a.example.com,b.example.org\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: fexec.ContextName() + "\n"},
		{match: "", status: 0},
	}}
	var out, errOut bytes.Buffer
	if status := HelmDeploy(r, modules, imageRepo, "1.2.3", true, &out, &errOut); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, errOut.String())
	}
	if len(r.calls) != 2 {
		t.Fatalf("calls = %q", r.calls)
	}
	call := r.calls[1]
	for _, want := range []string{
		"helm --kube-context " + fexec.ContextName() + " upgrade --install devzone-workspace",
		"--namespace devzone-workspace --create-namespace",
		"--set image.repository=" + imageRepo,
		"--set image.tag=1.2.3",
		`--set egressProxy.enabled=true`,
		`--set egressProxy.mode=strict`,
		`--set egressProxy.extraDomains=a.example.com\,b.example.org`,
	} {
		if !strings.Contains(call, want) {
			t.Fatalf("helm call %q does not contain %q", call, want)
		}
	}
	if strings.Contains(call, "pullPolicy") {
		t.Fatalf("a fixed tag must not force the pull policy: %q", call)
	}
}

// TestHelmDeployLatest checks that a floating tag forces Always, as the chart
// would otherwise keep an old image already present on the node.
func TestHelmDeployLatest(t *testing.T) {
	r := &fakeRunner{replies: []reply{{match: "config get-contexts"}, {match: "", status: 0}}}
	var out, errOut bytes.Buffer
	HelmDeploy(r, filepath.Join(t.TempDir(), "modules"), imageRepo, "latest", false, &out, &errOut)
	call := r.calls[len(r.calls)-1]
	if !strings.Contains(call, "helm upgrade") || !strings.Contains(call, "--set image.pullPolicy=Always") {
		t.Fatalf("helm call = %q", call)
	}
	if strings.Contains(call, "image.repository") {
		t.Fatalf("helm call = %q", call)
	}
}

// servicesHarness holds the fake kubectl of a services scenario.
type servicesHarness struct {
	t       *testing.T
	env     ServicesEnv
	out     bytes.Buffer
	errOut  bytes.Buffer
	modules string
}

// newServicesHarness prepares a running pod, a ready administrator and the
// token, without any cluster or real token.
func newServicesHarness(t *testing.T) *servicesHarness {
	t.Helper()
	h := &servicesHarness{t: t, modules: filepath.Join(t.TempDir(), ".devzone.modules")}
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: fexec.ContextName() + "\n"},
		{match: "get pod", stdout: "Running"},
		{match: "apply -f -", status: 0},
		{match: "create token", stdout: "TOKEN-123\n"},
		{match: "exec -i", status: 0},
		{match: "delete", status: 0},
		{match: "", status: 0},
	}}
	h.env = ServicesEnv{Runner: r, Modules: h.modules, Out: &h.out, ErrOut: &h.errOut, Script: "/fake/services-admin.sh"}
	return h
}

// TestServicesEnable checks the whole path and that the token goes only to
// the standard input of kubectl exec.
func TestServicesEnable(t *testing.T) {
	h := newServicesHarness(t)
	if status := h.env.Run([]string{"enable", "gitlab", "--yes"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if !strings.Contains(h.out.String(), "✔ enable gitlab done; in the pod: devzone status") {
		t.Fatalf("out = %q", h.out.String())
	}
	if strings.Contains(h.out.String(), "TOKEN-123") || strings.Contains(h.errOut.String(), "TOKEN-123") {
		t.Fatal("the token was printed")
	}
	data, err := os.ReadFile(h.modules)
	if err != nil || string(data) != "gitlab=on\n" {
		t.Fatalf("state = %q, err = %v", data, err)
	}
	calls := h.env.Runner.(*fakeRunner).calls
	joined := strings.Join(calls, "\n")
	for _, want := range []string{
		"--context " + fexec.ContextName() + " apply -f -",
		"--context " + fexec.ContextName() + " create token devzone-services-admin --namespace devzone-workspace --duration 1h",
		"--context " + fexec.ContextName() + " exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- devzone services-admin enable gitlab --yes",
		"--context " + fexec.ContextName() + " delete clusterrolebinding devzone-services-admin --ignore-not-found",
		"--context " + fexec.ContextName() + " delete serviceaccount devzone-services-admin --namespace devzone-workspace --ignore-not-found",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("calls %q do not contain %q", joined, want)
		}
	}
	input := strings.Join(h.env.Runner.(*fakeRunner).stdins, "\n")
	if !strings.Contains(input, "TOKEN-123\n") {
		t.Fatalf("the token was not piped to kubectl: %q", input)
	}
}

// TestServicesSeedAndRefusals checks seed, an unknown service, a pod that is
// not running and a failing installer: the administrator is always removed.
func TestServicesSeedAndRefusals(t *testing.T) {
	t.Run("seed gitlab writes no state", func(t *testing.T) {
		h := newServicesHarness(t)
		if status := h.env.Run([]string{"seed", "gitlab"}); status != 0 {
			t.Fatalf("status = %d", status)
		}
		if _, err := os.Stat(h.modules); !os.IsNotExist(err) {
			t.Fatal("seed wrote the modules file")
		}
	})
	t.Run("seed postgres refused", func(t *testing.T) {
		h := newServicesHarness(t)
		if status := h.env.Run([]string{"seed", "postgres"}); status != 1 ||
			!strings.Contains(h.errOut.String(), "seed: only gitlab") {
			t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
		}
		if strings.Contains(strings.Join(h.env.Runner.(*fakeRunner).calls, "\n"), "config get-contexts") {
			t.Fatal("kubectl called before the seed check")
		}
	})
	t.Run("pod not running", func(t *testing.T) {
		h := newServicesHarness(t)
		h.env.Runner.(*fakeRunner).replies[1] = reply{match: "get pod", stdout: "Pending"}
		if status := h.env.Run([]string{"enable", "gitlab"}); status != 1 ||
			!strings.Contains(h.errOut.String(), "not running") {
			t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
		}
		if strings.Contains(strings.Join(h.env.Runner.(*fakeRunner).calls, "\n"), "apply -f -") {
			t.Fatal("the administrator was created with no running pod")
		}
	})
	t.Run("installer fails", func(t *testing.T) {
		h := newServicesHarness(t)
		h.env.Runner.(*fakeRunner).replies[4] = reply{match: "exec -i", status: 3}
		if status := h.env.Run([]string{"disable", "gitlab"}); status != 3 ||
			!strings.Contains(h.errOut.String(), "failed (code 3)") {
			t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
		}
		if !strings.Contains(strings.Join(h.env.Runner.(*fakeRunner).calls, "\n"), "delete serviceaccount") {
			t.Fatal("the administrator was not removed after the failure")
		}
		if _, err := os.Stat(h.modules); !os.IsNotExist(err) {
			t.Fatal("state was written after a failure")
		}
	})
}

// TestServicesDisablePostgresYes checks --yes reaches the installer and no
// deprecation is printed (#557).
func TestServicesDisablePostgresYes(t *testing.T) {
	h := newServicesHarness(t)
	if status := h.env.Run([]string{"disable", "postgres", "--yes"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	calls := strings.Join(h.env.Runner.(*fakeRunner).calls, "\n")
	if !strings.Contains(calls, "devzone services-admin disable postgres --yes") {
		t.Fatalf("calls = %q", calls)
	}
	if strings.Contains(h.errOut.String(), "deprecated") {
		t.Fatalf("deprecated printed: %q", h.errOut.String())
	}
}

// TestServicesSeedRunsInPod checks seed gitlab runs services-admin.sh seed
// gitlab in the pod (#538).
func TestServicesSeedRunsInPod(t *testing.T) {
	h := newServicesHarness(t)
	if status := h.env.Run([]string{"seed", "gitlab"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	calls := strings.Join(h.env.Runner.(*fakeRunner).calls, "\n")
	if !strings.Contains(calls, "devzone services-admin seed gitlab") {
		t.Fatalf("calls = %q", calls)
	}
}

// TestServicesUnknownService checks an unknown service is refused before any
// cluster call.
func TestServicesUnknownService(t *testing.T) {
	h := newServicesHarness(t)
	if status := h.env.Run([]string{"enable", "redis"}); status != 1 || !strings.Contains(h.errOut.String(), "unknown service: redis") {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if len(h.env.Runner.(*fakeRunner).calls) != 0 {
		t.Fatalf("cluster called: %q", h.env.Runner.(*fakeRunner).calls)
	}
}
