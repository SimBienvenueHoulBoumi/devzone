package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// egressScript is the bash original of the egress command, sourced by
// workspace.sh after workspace-update.sh.
const egressScript = "../../manage/scripts/workspace/workspace-egress.sh"

// egressBashHarness runs functions of the shell original with fake kubectl and
// helm, and prepares the same answers for the Go implementation.
type egressBashHarness struct {
	t   *testing.T
	dir string
	bin string
}

// newEgressBashHarness skips on Windows and without bash, and writes the fake
// programs: kubectl logs its calls and replays FAKE_* answers, helm is present.
func newEgressBashHarness(t *testing.T) *egressBashHarness {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the bash original does not run on Windows")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	kubectl := `#!/usr/bin/env bash
case "$*" in
*"config get-contexts"*) exit 0 ;;
*"cluster-info"*) exit 0 ;;
*"get service egress-proxy"*) printf '%s' "${FAKE_MODE:-}" ;;
*) exit 0 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "helm"), []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &egressBashHarness{t: t, dir: dir, bin: bin}
}

// shell runs body in the sourced original and returns its combined output.
func (h *egressBashHarness) shell(body string) string {
	h.t.Helper()
	path, err := filepath.Abs(egressScript)
	if err != nil {
		h.t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", `. "$1"; `+body, "_", path)
	cmd.Dir = h.dir
	cmd.Env = append(os.Environ(), "PATH="+h.bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"FAKE_MODE="+os.Getenv("FAKE_MODE"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		h.t.Fatalf("bash failed: %v\n%s", err, out)
	}
	return string(out)
}

// TestEgressParamsMatchesBash compares the chart parameters written by both
// implementations for the same state, with state_read and readModulesKey.
func TestEgressParamsMatchesBash(t *testing.T) {
	h := newEgressBashHarness(t)
	for _, content := range []string{"", "egress=off\n", "egress=strict\n",
		"egress=observation\negress_domains=a.example.com,b.example.org\n"} {
		path := filepath.Join(h.dir, ".devzone.modules")
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		h.t.Setenv("FAKE_MODULES", path)
		want := h.shell(`state_read() { grep "^$1=" "$FAKE_MODULES" 2>/dev/null | tail -1 | cut -d= -f2- || true; }; egress_params`)
		got := EgressParams(path)
		if strings.TrimSpace(want) != strings.TrimSpace(got) {
			t.Fatalf("state %q: bash %q, Go %q", content, want, got)
		}
	}
}

// TestEgressStatusOffMatchesBash checks the egress-off line: the readiness
// check passes with the fake programs and the proxy Service is absent.
func TestEgressStatusOffMatchesBash(t *testing.T) {
	h := newEgressBashHarness(t)
	h.t.Setenv("FAKE_MODE", "")
	h.t.Setenv("PATH", h.bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	want := h.shell(`NAMESPACE=devzone-workspace; kube_ready_reason() { return 0; }; ak() { kubectl "$@"; }; egress_status`)
	var out, errOut strings.Builder
	runner := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "cluster-info"},
		{match: "", stdout: ""},
	}}
	status := egressStatus(kubeEnv{runner: runner, lookPath: egressLook}, &out, &errOut)
	if status != 0 || strings.TrimSpace(out.String()) != strings.TrimSpace(want) {
		t.Fatalf("bash %q (%s), Go %q (%s) status %d", want, errOut.String(), out.String(), errOut.String(), status)
	}
}
