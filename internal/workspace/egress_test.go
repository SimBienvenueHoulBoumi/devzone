package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// egressLook answers every program lookup, so a test never asks the real PATH
// for kubectl or helm.
func egressLook(string) (string, error) { return "/fake/program", nil }

// egressHarness holds a temporary modules file and a fake Runner whose cluster
// is ready, with the replies of one scenario.
type egressHarness struct {
	t       *testing.T
	modules string
	runner  *fakeRunner
	out     bytes.Buffer
	errOut  bytes.Buffer
}

// newEgressHarness builds a harness with the common ready-cluster replies.
func newEgressHarness(t *testing.T, replies ...reply) *egressHarness {
	t.Helper()
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "cluster-info", status: 0},
	}}
	return &egressHarness{t: t, modules: filepath.Join(t.TempDir(), ".devzone.modules"), runner: appendReplies(r, replies)}
}

// appendReplies adds scenario replies before the catch-all answer.
func appendReplies(r *fakeRunner, replies []reply) *fakeRunner {
	r.replies = append(r.replies, replies...)
	r.replies = append(r.replies, reply{match: "", stdout: ""})
	return r
}

// env returns the EgressEnv of the harness with a deploy that records calls.
func (h *egressHarness) env(deployed *[][]string) EgressEnv {
	return EgressEnv{
		Runner: h.runner, Modules: h.modules, Out: &h.out, ErrOut: &h.errOut,
		LookPath: egressLook, Sleep: func(time.Duration) {},
		Deploy: func(repository, tag, revision string) int {
			*deployed = append(*deployed, []string{repository, tag, revision})
			return 0
		},
	}
}

// writeModules writes the content of the modules file.
func (h *egressHarness) writeModules(content string) {
	h.t.Helper()
	if err := os.WriteFile(h.modules, []byte(content), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

// state reads the modules file.
func (h *egressHarness) state() string {
	h.t.Helper()
	data, err := os.ReadFile(h.modules)
	if err != nil {
		h.t.Fatal(err)
	}
	return string(data)
}

// TestEgressParamsAndDomain checks the chart parameters and the domain rule.
func TestEgressParamsAndDomain(t *testing.T) {
	for _, tc := range []struct{ modules, want string }{
		{"", ""},
		{"egress=off\n", ""},
		{"egress=strict\n", "egressProxy.enabled=true egressProxy.mode=strict"},
		{"egress=observation\negress_domains=a.example.com,b.example.org\n",
			"egressProxy.enabled=true egressProxy.mode=observation egressProxy.extraDomains=a.example.com,b.example.org"},
	} {
		path := filepath.Join(t.TempDir(), ".devzone.modules")
		if err := os.WriteFile(path, []byte(tc.modules), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := EgressParams(path); got != tc.want {
			t.Fatalf("modules %q: params = %q, want %q", tc.modules, got, tc.want)
		}
	}
	for _, domain := range []string{"a.example.com", ".cdn.example.org", "a-b.example.org"} {
		if !EgressDomainOK(domain) {
			t.Fatalf("%q refused", domain)
		}
	}
	for _, domain := range []string{"Bad.Example.com", "a,b.example.com", "*.example.com", "nodot", "a..example.com"} {
		if EgressDomainOK(domain) {
			t.Fatalf("%q accepted", domain)
		}
	}
}

// TestEgressSetModeWithoutApplication checks that a mode is memorised before
// anything is deployed, and kept when there is no Argo CD Application.
func TestEgressSetModeWithoutApplication(t *testing.T) {
	h := newEgressHarness(t)
	h.writeModules("workspace=kubernetes\n")
	var deployed [][]string
	status := h.env(&deployed).Run([]string{"strict"})
	if status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if got := h.state(); got != "workspace=kubernetes\negress=strict\n" {
		t.Fatalf("state = %q", got)
	}
	if len(deployed) != 0 {
		t.Fatalf("deploy called %v", deployed)
	}
	want := "ℹ no Argo CD Application: the setting is kept, devzone workspace start applies it\n" +
		"✔ egress strict\n" +
		"ℹ strict: only the devzone agent sessions started with --pod are filtered; the workspace stays open\n"
	if h.out.String() != want {
		t.Fatalf("out = %q, want %q", h.out.String(), want)
	}
}

// TestEgressSetModeWithApplication checks the redeploy at the image of the
// Application and the wait for the proxy.
func TestEgressSetModeWithApplication(t *testing.T) {
	h := newEgressHarness(t,
		reply{match: "get application.argoproj.io devzone-workspace", stdout: "v0.48.0 0.48.0"},
		reply{match: "get deployment devzone-workspace-egress-proxy", status: 0},
		reply{match: "rollout status", status: 0})
	h.writeModules("workspace=kubernetes\n")
	var deployed [][]string
	status := h.env(&deployed).Run([]string{"observation"})
	if status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	if len(deployed) != 1 || strings.Join(deployed[0], " ") != imageRepo+" 0.48.0 v0.48.0" {
		t.Fatalf("deploy = %v", deployed)
	}
	if !strings.Contains(h.out.String(), "▶ waiting for the egress proxy…") {
		t.Fatalf("out = %q", h.out.String())
	}
	if !strings.Contains(strings.Join(h.runner.calls, "\n"), "rollout status deployment/devzone-workspace-egress-proxy --timeout=120s") {
		t.Fatalf("calls = %q", h.runner.calls)
	}
}

// TestEgressDomainEdit checks allow, deny, duplicates and the base list.
func TestEgressDomainEdit(t *testing.T) {
	h := newEgressHarness(t)
	h.writeModules("egress=strict\n")
	var deployed [][]string
	env := h.env(&deployed)
	if status := env.Run([]string{"allow", "api.example.com"}); status != 0 {
		t.Fatalf("allow status = %d", status)
	}
	if !strings.Contains(h.state(), "egress_domains=api.example.com\n") {
		t.Fatalf("state = %q", h.state())
	}
	if status := env.Run([]string{"allow", ".npmjs.org"}); status != 0 ||
		!strings.Contains(h.out.String(), "is in the base list") {
		t.Fatalf("base allow: status = %d, out = %q", status, h.out.String())
	}
	if status := env.Run([]string{"deny", ".npmjs.org"}); status != 1 ||
		!strings.Contains(h.errOut.String(), "egressProxy.allowedDomains") {
		t.Fatalf("base deny: status = %d, errOut = %q", status, h.errOut.String())
	}
	if status := env.Run([]string{"deny", "api.example.com"}); status != 0 ||
		!strings.Contains(h.state(), "egress_domains=\n") {
		t.Fatalf("deny status = %d, state = %q", status, h.state())
	}
	if status := env.Run([]string{"allow", "Bad.Example.com"}); status != 1 ||
		!strings.Contains(h.errOut.String(), "domain not valid") {
		t.Fatalf("invalid domain accepted: %q", h.errOut.String())
	}
}

// TestEgressStatusOutput checks the summary and the access log table.
func TestEgressStatusOutput(t *testing.T) {
	config := "acl allowed dstdomain .opencode.ai\nacl allowed dstdomain .github.com\n"
	logs := "1700000000.000 5 10.0.0.1 TCP_TUNNEL/200 1234 CONNECT .opencode.ai:443 - HIER_DIRECT/1.2.3.4 -\n" +
		"1700000001.000 0 10.0.0.1 TCP_DENIED/403 3456 CONNECT evil.example.net:443 - HIER_NONE/- text/html\n" +
		"1700000002.000 5 10.0.0.1 TCP_MISS/200 1234 GET http://plain.example.org/ - HIER_DIRECT/1.2.3.4 text/html\n"
	h := newEgressHarness(t,
		reply{match: "get service egress-proxy", stdout: "strict"},
		reply{match: "get deployment devzone-workspace-egress-proxy", stdout: "1"},
		reply{match: "get configmap devzone-workspace-egress-proxy", stdout: config},
		reply{match: "logs deployment/devzone-workspace-egress-proxy", stdout: logs})
	var deployed [][]string
	if status := h.env(&deployed).Run([]string{"status"}); status != 0 {
		t.Fatalf("status = %d, errOut = %q", status, h.errOut.String())
	}
	out := h.out.String()
	if !strings.Contains(out, "egress strict, proxy ready, allowed domains: 2\n") ||
		!strings.Contains(out, ".opencode.ai") || !strings.Contains(out, "evil.example.net") ||
		strings.Contains(out, "plain.example.org") {
		t.Fatalf("out = %q", out)
	}
}

// TestEgressArguments checks the two dispatch errors and the cluster refusal.
func TestEgressArguments(t *testing.T) {
	h := newEgressHarness(t)
	var deployed [][]string
	env := h.env(&deployed)
	if status := env.Run(nil); status != 1 || !strings.Contains(h.errOut.String(), "unknown egress argument: none") {
		t.Fatalf("missing argument: status = %d, errOut = %q", status, h.errOut.String())
	}
	h.errOut.Reset()
	if status := env.Run([]string{"allow"}); status != 1 || !strings.Contains(h.errOut.String(), "takes one domain") {
		t.Fatalf("allow without domain: status = %d, errOut = %q", status, h.errOut.String())
	}
	h.errOut.Reset()
	env.LookPath = func(name string) (string, error) { return "", os.ErrNotExist }
	if status := env.Run([]string{"off"}); status != 1 || !strings.Contains(h.errOut.String(), "kubectl missing") {
		t.Fatalf("cluster refusal: status = %d, errOut = %q", status, h.errOut.String())
	}
	if _, err := os.Stat(h.modules); !os.IsNotExist(err) {
		t.Fatal("the modules file was written before the cluster check")
	}
}
