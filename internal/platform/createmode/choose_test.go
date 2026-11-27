package createmode

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// modeLookPath finds only the named programs, so the decision never asks the
// real PATH whether kubectl or helm is installed.
func modeLookPath(names ...string) func(string) (string, error) {
	return func(name string) (string, error) {
		for _, n := range names {
			if n == name {
				return "/fake/" + name, nil
			}
		}
		return "", errors.New(name + " not found")
	}
}

// modeSession builds a session around a fake runner and captures its output.
func modeSession(t *testing.T, programs []string, setup func(*fake.Runner)) (*Session, *fake.Runner, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	r := fake.New()
	if setup != nil {
		setup(r)
	}
	var out, errOut bytes.Buffer
	s := &Session{
		Runner:   r,
		LookPath: modeLookPath(programs...),
		Out:      &out,
		Err:      &errOut,
	}
	return s, r, &out, &errOut
}

// modeReady programs a reachable devzone context.
func modeReady(r *fake.Runner) {
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{})
}

// modeUnreachable programs a devzone context that does not answer.
func modeUnreachable(r *fake.Runner) {
	modeReady(r)
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{Code: 1})
	r.On("kubectl", []string{"config", "view", "--minify", "--context", "devzone", "-o", `jsonpath={.clusters[0].cluster.server}`},
		exec.Result{Stdout: []byte("https://127.0.0.1:6443\n")})
}

// TestChooseReady checks that a reachable cluster selects kubernetes with the
// context in the notice, with or without the explicit option.
func TestChooseReady(t *testing.T) {
	for _, option := range []string{"", "kubernetes"} {
		t.Run("option="+option, func(t *testing.T) {
			s, _, out, errOut := modeSession(t, []string{"kubectl", "helm"}, modeReady)
			mode, ok := s.Choose(option)
			if !ok || mode != "kubernetes" {
				t.Fatalf("mode = %q, ok = %v; want kubernetes", mode, ok)
			}
			if !strings.Contains(out.String(), "✔ Kubernetes ready (devzone): workspace in the cluster") || errOut.Len() != 0 {
				t.Fatalf("out = %q, err = %q", out.String(), errOut.String())
			}
		})
	}
}

// TestChooseUnreachable checks that no mode is chosen and that the ways to get
// a cluster are displayed but never run.
func TestChooseUnreachable(t *testing.T) {
	s, r, _, errOut := modeSession(t, []string{"kubectl", "helm"}, modeUnreachable)
	mode, ok := s.Choose("")
	if ok || mode != "" {
		t.Fatalf("mode = %q, ok = %v; want no mode", mode, ok)
	}
	for _, want := range []string{
		"✖ Kubernetes not reachable: cluster devzone unreachable (https://127.0.0.1:6443). Nothing created.",
		"kubectl config use-context",
		"minikube start -p devzone",
	} {
		if !strings.Contains(errOut.String(), want) {
			t.Fatalf("err = %q; want %q", errOut.String(), want)
		}
	}
	for _, call := range r.Calls() {
		if call.Name != "kubectl" {
			t.Fatalf("call = %+v; only the cluster check may run", call)
		}
	}
}

// TestChooseMissingProgram checks that a missing program gives its reason and
// no mode before any command is run.
func TestChooseMissingProgram(t *testing.T) {
	s, r, _, errOut := modeSession(t, []string{"kubectl"}, nil)
	mode, ok := s.Choose("kubernetes")
	if ok || mode != "" || !strings.Contains(errOut.String(), "helm missing") {
		t.Fatalf("mode = %q, ok = %v, err = %q", mode, ok, errOut.String())
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("calls = %+v; want none", r.Calls())
	}
}

// TestChooseExistingWorkspace checks that a helm release already installed is
// named in a notice without changing the chosen mode.
func TestChooseExistingWorkspace(t *testing.T) {
	setup := func(r *fake.Runner) {
		modeReady(r)
		r.On("helm", []string{"status", "devzone-workspace", "--namespace", "devzone-workspace", "--kube-context", "devzone"}, exec.Result{})
	}
	s, _, out, _ := modeSession(t, []string{"kubectl", "helm"}, setup)
	mode, ok := s.Choose("")
	if !ok || mode != "kubernetes" {
		t.Fatalf("mode = %q, ok = %v", mode, ok)
	}
	if !strings.Contains(out.String(), "ℹ a devzone workspace already runs in this cluster") {
		t.Fatalf("out = %q; want the existing-workspace notice", out.String())
	}
}

// TestChooseExistingApplication checks that an Argo CD Application is also
// recognized as an already running workspace.
func TestChooseExistingApplication(t *testing.T) {
	setup := func(r *fake.Runner) {
		modeReady(r)
		r.On("kubectl", []string{"get", "application.argoproj.io", "devzone-workspace", "--namespace", "devzone-argocd", "--context", "devzone"}, exec.Result{})
	}
	s, _, out, _ := modeSession(t, []string{"kubectl", "helm"}, setup)
	if _, ok := s.Choose("kubernetes"); !ok {
		t.Fatal("choice failed")
	}
	if !strings.Contains(out.String(), "ℹ a devzone workspace already runs in this cluster") {
		t.Fatalf("out = %q; want the existing-workspace notice", out.String())
	}
}

// TestChooseCurrentContext checks that a cluster without a devzone context is
// described with the current context name.
func TestChooseCurrentContext(t *testing.T) {
	setup := func(r *fake.Runner) {
		r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("lab\n")})
		r.On("kubectl", []string{"cluster-info", "--request-timeout=5s"}, exec.Result{})
		r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("kind-poste\n")})
	}
	s, _, out, _ := modeSession(t, []string{"kubectl", "helm"}, setup)
	if _, ok := s.Choose(""); !ok {
		t.Fatal("choice failed")
	}
	if !strings.Contains(out.String(), "✔ Kubernetes ready (kind-poste): workspace in the cluster") {
		t.Fatalf("out = %q; want the current context name", out.String())
	}
}

// TestChooseMenuCancelled checks that cancelling the menu leaves no mode and
// still explains how to get a cluster.
func TestChooseMenuCancelled(t *testing.T) {
	s, _, _, errOut := modeSession(t, []string{"kubectl", "helm"}, modeUnreachable)
	s.Terminal = true
	s.In = strings.NewReader("\n")
	mode, ok := s.Choose("")
	if ok || mode != "" {
		t.Fatalf("mode = %q, ok = %v; want no mode", mode, ok)
	}
	if !strings.Contains(errOut.String(), "✖ cancelled") || !strings.Contains(errOut.String(), "Nothing created") {
		t.Fatalf("err = %q", errOut.String())
	}
}
