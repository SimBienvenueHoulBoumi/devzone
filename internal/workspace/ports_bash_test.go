package workspace

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// portsScript is the bash original of the port watcher; it sources ports-apps.sh
// and runs nothing when sourced
const portsScript = "../../manage/scripts/workspace/ports-workspace.sh"

// bashHarness runs functions of the bash original: a folder that holds the fake
// kubectl in its bin folder and the modules file, and the path of the script
type bashHarness struct {
	t      *testing.T
	dir    string
	script string
}

// newBashHarness skips the test when bash is missing or on Windows, as the bash
// original cannot run there, and else prepares a folder with the fake kubectl:
// it logs its arguments in kubectl.log and replays the output set in FAKE_*
func newBashHarness(t *testing.T) *bashHarness {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the bash original does not run on Windows")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	script, err := filepath.Abs(filepath.FromSlash(portsScript))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	kubectl := `#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
case "$*" in
*"config get-contexts"*) printf '%s' "$FAKE_CONTEXTS" ;;
*"get endpointslices"*) [ -z "$FAKE_READY_FAIL" ] || exit 1; printf '%s' "$FAKE_READY" ;;
*"get svc -A"*) printf '%s' "$FAKE_SVC" ;;
*"svc pgadmin"*) printf '%s' "$FAKE_PGADMIN" ;;
*"svc argocd-server"*) printf '%s' "$FAKE_ARGO" ;;
*"ss -ltnH"*) [ -z "$FAKE_SS_FAIL" ] || exit 1; printf '%s' "$FAKE_SS" ;;
*) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "bin", "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	return &bashHarness{t: t, dir: dir, script: script}
}

// run sources the bash original, then runs body, with stdin and the extra
// environment; it returns the standard output and fails the test on a bash error
func (h *bashHarness) run(body, stdin string, env ...string) string {
	h.t.Helper()
	cmd := exec.Command("bash", "-c", `. "$1"; `+body, "_", h.script)
	cmd.Dir = h.dir
	cmd.Env = append(os.Environ(), "LC_ALL=C", "PATH="+filepath.Join(h.dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	cmd.Env = append(cmd.Env, env...)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	if err != nil {
		h.t.Fatalf("bash failed: %v\n%s", err, out)
	}
	return string(out)
}

// TestExcludedMatchesBash gives the same Services to pa_excluded and to
// serviceExcluded, including each rule and the boundaries of the namespace list
func TestExcludedMatchesBash(t *testing.T) {
	h := newBashHarness(t)
	var inputs [][5]string
	for _, ns := range append(strings.Fields("kube-system kube-public kube-node-lease local-path-storage devzone-system devzone-workspace devzone-postgres devzone-mysql devzone-argocd devzone-gitlab devzone-llm"), "", "kube", "system", "kube-system2", "devzone", "default", "shop", "kube-system kube-public") {
		inputs = append(inputs, [5]string{ns, "web", "10.0.0.1", "ClusterIP", ""})
	}
	for _, ip := range []string{"", "None", "none", "10.0.0.1"} {
		for _, typ := range []string{"ClusterIP", "ExternalName", "externalname", "NodePort", ""} {
			for _, annotation := range []string{"", "false", "true", "False", "other"} {
				inputs = append(inputs, [5]string{"shop", "web", ip, typ, annotation})
			}
		}
	}
	inputs = append(inputs, [5]string{"default", "kubernetes", "10.0.0.1", "ClusterIP", ""},
		[5]string{"default", "kubernetes2", "10.0.0.1", "ClusterIP", ""},
		[5]string{"shop", "kubernetes", "10.0.0.1", "ClusterIP", ""})
	var stdin, want strings.Builder
	for _, in := range inputs {
		stdin.WriteString(strings.Join(in[:], "|") + "\n")
		answer := "no"
		if serviceExcluded(in[0], in[1], in[2], in[3], in[4]) {
			answer = "yes"
		}
		want.WriteString(answer + "\n")
	}
	body := `while IFS='|' read -r a b c d e; do if pa_excluded "$a" "$b" "$c" "$d" "$e"; then echo yes; else echo no; fi; done`
	got := h.run(body, stdin.String())
	if got != want.String() {
		gl, wl := strings.Split(got, "\n"), strings.Split(want.String(), "\n")
		for i := range wl {
			if i >= len(gl) || gl[i] != wl[i] {
				t.Fatalf("input %q: bash says %q, Go says %q", inputs[i], gl[i], wl[i])
			}
		}
	}
}

// TestNewLocalPortMatchesBash gives the same used ports and the same free
// range to pa_new and to newLocalPort; "fail" is the answer of both when no
// port is free. The taken test of the shell is replaced by a free range.
func TestNewLocalPortMatchesBash(t *testing.T) {
	h := newBashHarness(t)
	cases := []struct {
		port   int
		used   string
		lo, hi int
	}{
		{80, "", 1, 65535}, {0, "", 1, 65535}, {5432, "", 1, 65535}, {1023, "", 1, 65535},
		{1024, "", 1, 65535}, {1024, "1024", 1, 65535}, {1025, "1025 9025", 1, 65535},
		{5432, "", 5433, 65535}, {80, "8080", 1, 65535}, {80, "8080 8081 8082", 1, 65535},
		{80, "", 8082, 65535}, {57000, "", 1, 65535}, {57001, "", 1, 65535},
		{56999, "", 65001, 65535}, {56999, "64999 65000", 1, 65535},
		{56999, "64999 65000 20000", 1, 65535}, {65000, "65000", 1, 65535},
		{65535, "", 1, 65535}, {60000, "", 1, 65535}, {80, "", 20000, 20010},
		{80, "", 65000, 65000}, {80, "", 8080, 8080}, {5000, "5000 13000", 13001, 13001},
		{80, "", 65001, 65535}, {80, "", 1, 0},
	}
	var stdin, want strings.Builder
	for _, c := range cases {
		fmt.Fprintf(&stdin, "%d|%s|%d|%d\n", c.port, c.used, c.lo, c.hi)
		var used []int
		for _, f := range strings.Fields(c.used) {
			n, _ := strconv.Atoi(f)
			used = append(used, n)
		}
		got, err := newLocalPort(c.port, used, takenOutside(c.lo, c.hi))
		if err != nil {
			want.WriteString("fail\n")
		} else {
			want.WriteString(strconv.Itoa(got) + "\n")
		}
	}
	body := `pw_taken() { [ "$1" -lt "$FLO" ] || [ "$1" -gt "$FHI" ]; }
while IFS='|' read -r port used FLO FHI; do
    if r="$(pa_new "$port" " $used ")"; then echo "$r"; else echo fail; fi
done`
	got := h.run(body, stdin.String())
	gl, wl := strings.Split(got, "\n"), strings.Split(want.String(), "\n")
	for i := range wl {
		if i >= len(gl) || gl[i] != wl[i] {
			t.Fatalf("case %+v: bash says %q, Go says %q", cases[i], gl[i], wl[i])
		}
	}
}
