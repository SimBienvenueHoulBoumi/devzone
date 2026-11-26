package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRebuildFromNamespaces(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	home := filepath.Join(dir, "home")
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	run := fakeKubectlRunner(map[string]string{
		"kubectl get namespaces -l app.kubernetes.io/managed-by=devzone -o name":                                                                                        "namespace/devzone-postgres\nnamespace/devzone-gitlab\nnamespace/devzone-mysql\n",
		"kubectl config view -o jsonpath={.contexts[?(@.name==\"devzone\")].context.cluster}":                                                                           "docker-desktop",
		"env KUBECONFIG=" + filepath.Join(home, ".kube", "hote.config") + " kubectl config get-contexts -o name":                                                        "devzone\ndocker-desktop\n",
		"env KUBECONFIG=" + filepath.Join(home, ".kube", "hote.config") + " kubectl config view -o jsonpath={.contexts[?(@.name==\"docker-desktop\")].context.cluster}": "docker-desktop",
	})
	var warns []string
	s := At(path)
	if err := s.Init(defaultModules(), run, home, nil, func(m string) { warns = append(warns, m) }); err != nil {
		t.Fatal(err)
	}
	if s.Get("postgres") != "on" || s.Get("gitlab") != "on" || s.Get("mysql") != "on" || s.Get("ai") != "off" {
		t.Fatalf("state=%q", readFile(t, path))
	}
	if s.Get("cluster") != "docker-desktop" {
		t.Fatalf("cluster=%q", s.Get("cluster"))
	}
	if !s.RecoveryPending() || !containsAny(warns, "rebuilt from the namespaces") {
		t.Fatalf("warns=%v pending=%v", warns, s.RecoveryPending())
	}
}

func TestRebuildWithoutHostContext(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	home := filepath.Join(dir, "home")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	run := fakeKubectlRunner(map[string]string{
		"kubectl get namespaces -l app.kubernetes.io/managed-by=devzone -o name":                                 "namespace/devzone-postgres\nnamespace/devzone-gitlab\n",
		"kubectl config view -o jsonpath={.contexts[?(@.name==\"devzone\")].context.cluster}":                    "docker-desktop",
		"env KUBECONFIG=" + filepath.Join(home, ".kube", "hote.config") + " kubectl config get-contexts -o name": "",
	})
	var warns []string
	s := At(path)
	if err := s.Init(defaultModules(), run, home, nil, func(m string) { warns = append(warns, m) }); err != nil {
		t.Fatal(err)
	}
	if s.Get("postgres") != "on" {
		t.Fatalf("postgres=%q", s.Get("postgres"))
	}
	if _, ok := s.GetOK("cluster"); ok {
		t.Fatalf("unexpected cluster: %q", readFile(t, path))
	}
	if !containsAny(warns, "no host context") {
		t.Fatalf("warns=%v", warns)
	}
}

func TestFirstInstallDefaultState(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	s := At(path)
	warned := false
	if err := s.Init(defaultModules(), nil, dir, func() bool { return true }, func(string) { warned = true }); err != nil {
		t.Fatal(err)
	}
	if s.Get("ai") != "off" || s.Get("kubernetes") != "off" || s.Get("gitlab") != "off" {
		t.Fatalf("state=%q", readFile(t, path))
	}
	if _, err := os.Stat(path + ".prev"); err == nil {
		t.Fatal("unexpected prev")
	}
	if s.RecoveryPending() || !warned {
		t.Fatalf("pending=%v warned=%v", s.RecoveryPending(), warned)
	}
}

func TestRecoveryConfirmRemovesMarker(t *testing.T) {
	s := At(filepath.Join(t.TempDir(), ".devzone.modules"))
	if err := os.WriteFile(s.recoveryPath(), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !s.RecoveryPending() {
		t.Fatal("pending")
	}
	if err := s.RecoveryConfirm(); err != nil {
		t.Fatal(err)
	}
	if s.RecoveryPending() {
		t.Fatal("still pending")
	}
}

func TestRecoveryWaitAge(t *testing.T) {
	s := At(filepath.Join(t.TempDir(), ".devzone.modules"))
	if err := s.RecoveryMark(); err != nil {
		t.Fatal(err)
	}
	if !s.RecoveryWait() {
		t.Fatal("recent marker should wait")
	}
	old := time.Now().Add(-120 * time.Second).Unix()
	if err := os.WriteFile(s.recoveryPath(), []byte(fmtInt(old)), 0o644); err != nil {
		t.Fatal(err)
	}
	if s.RecoveryWait() {
		t.Fatal("old marker should not wait")
	}
}
