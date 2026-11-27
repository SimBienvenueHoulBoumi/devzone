package create

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestCreateKubernetesRecordedNoStart checks a ready cluster records
// workspace=kubernetes, prints the ready notice and start-only message, and
// writes .argocd.conf with repo none, without starting anything.
func TestCreateKubernetesRecordedNoStart(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	opts, target, out, errOut := createOptions(t, readyRunner())
	if err := Create(opts); err != nil {
		t.Fatalf("Create: %v", err)
	}
	modules, err := os.ReadFile(filepath.Join(target, ".devzone.modules"))
	if err != nil {
		t.Fatal(err)
	}
	if string(modules) != "workspace=kubernetes\n" {
		t.Fatalf(".devzone.modules = %q", modules)
	}
	conf, err := os.ReadFile(filepath.Join(target, ".argocd.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(conf), "[argocd]") || !strings.Contains(string(conf), "repo = none") {
		t.Fatalf(".argocd.conf:\n%s", conf)
	}
	for _, f := range []string{"Makefile", ".gitignore", ".devzone.version",
		"manage/scripts/uninstall.sh", "workspace/.gitkeep"} {
		if !fileExists(filepath.Join(target, filepath.FromSlash(f))) {
			t.Fatalf("%s missing in %s", f, target)
		}
	}
	if !strings.Contains(out.String(), "To start the workspace: cd ") {
		t.Fatalf("stdout:\n%s\nstderr:\n%s", out.String(), errOut.String())
	}
	if !strings.Contains(out.String(), "devzone 9.9.9 created in") {
		t.Fatalf("stdout:\n%s", out.String())
	}
}

// TestCreateNotices checks the cluster-ready notice on stderr and the
// no-GitOps notice on stderr when no repository is named and no terminal.
func TestCreateNotices(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	opts, _, _, errOut := createOptions(t, readyRunner())
	opts.Gitops = ""
	if err := Create(opts); err != nil {
		t.Fatalf("Create: %v", err)
	}
	s := errOut.String()
	if !strings.Contains(s, "✔ Kubernetes ready (devzone): workspace in the cluster") {
		t.Fatalf("stderr:\n%s", s)
	}
	if !strings.Contains(s, "no GitOps repository for Argo CD") {
		t.Fatalf("stderr:\n%s", s)
	}
}

// TestCreateUnknownOptionRefused checks ParseArgs refusals: --docker in
// particular is an unknown option, and a trailing --gitops needs a value.
func TestCreateUnknownOptionRefused(t *testing.T) {
	for _, arg := range []string{"--docker", "--bogus", "extra"} {
		if _, _, err := ParseArgs([]string{arg}); err == nil {
			t.Fatalf("ParseArgs(%q) accepted", arg)
		}
	}
	if _, _, err := ParseArgs([]string{"--kubernetes", "--gitops", "none"}); err != nil {
		t.Fatalf("ParseArgs refused valid args: %v", err)
	}
	if _, _, err := ParseArgs([]string{"--gitops=https://example.com/x.git"}); err != nil {
		t.Fatalf("ParseArgs refused --gitops=...: %v", err)
	}
	if _, _, err := ParseArgs([]string{"--gitops"}); err == nil {
		t.Fatal("trailing --gitops accepted")
	}
	gitops, kubernetes, err := ParseArgs([]string{"--gitops", "none", "--kubernetes"})
	if err != nil || gitops != "none" || !kubernetes {
		t.Fatalf("gitops=%q kubernetes=%v err=%v", gitops, kubernetes, err)
	}
}

// TestCreateRefusesNonEmptyTarget checks a non-empty target is refused before
// anything is written and no external command runs.
func TestCreateRefusesNonEmptyTarget(t *testing.T) {
	runner := readyRunner()
	opts, target, _, _ := createOptions(t, runner)
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "important"), []byte("keep\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Create(opts); err == nil {
		t.Fatal("non-empty target accepted")
	}
	if len(runner.Calls()) != 0 {
		t.Fatalf("external commands ran: %+v", runner.Calls())
	}
	data, _ := os.ReadFile(filepath.Join(target, "important"))
	if string(data) != "keep\n" {
		t.Fatal("existing file touched")
	}
}

// TestCreateClusterUnreachable checks nothing is created when the cluster does
// not answer, in plain and --kubernetes modes.
func TestCreateClusterUnreachable(t *testing.T) {
	for _, kubernetes := range []bool{false, true} {
		runner := readyRunner()
		runner.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, fexec.Result{Code: 1})
		opts, target, _, errOut := createOptions(t, runner)
		opts.Kubernetes = kubernetes
		err := Create(opts)
		if err == nil {
			t.Fatalf("kubernetes=%v: unreachable cluster accepted", kubernetes)
		}
		if err != ErrSilent {
			t.Fatalf("kubernetes=%v: err=%v", kubernetes, err)
		}
		if fileExists(target) {
			t.Fatalf("kubernetes=%v: %s created", kubernetes, target)
		}
		if !strings.Contains(errOut.String(), "Kubernetes not reachable") || !strings.Contains(errOut.String(), "Nothing created") {
			t.Fatalf("kubernetes=%v stderr:\n%s", kubernetes, errOut.String())
		}
	}
}

// fileExists tells whether path exists.
func fileExists(path string) bool { _, err := os.Stat(path); return err == nil }
