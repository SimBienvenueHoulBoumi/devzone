package argocd

import (
	"bytes"
	"strings"
	"testing"
)

func TestRenderApplication(t *testing.T) {
	var b bytes.Buffer
	if err := RenderApplication(&b, "devzone-postgres", "service", "devzone-postgres", "https://github.com/x/devzone.git", "v1.2.3", "charts/devzone-postgres", nil, ""); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		"apiVersion: argoproj.io/v1alpha1",
		"kind: Application",
		"  name: devzone-postgres",
		"  namespace: devzone-argocd",
		"devzone.io/kind: service",
		"app.kubernetes.io/managed-by: devzone",
		"- resources-finalizer.argocd.argoproj.io",
		"repoURL: https://github.com/x/devzone.git",
		"targetRevision: v1.2.3",
		"path: charts/devzone-postgres",
		"server: https://kubernetes.default.svc",
		"    namespace: devzone-postgres",
		"prune: true",
		"selfHeal: true",
		"- CreateNamespace=true",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "helm:") {
		t.Fatalf("unexpected helm in:\n%s", out)
	}
}

func TestRenderApplicationHelmParams(t *testing.T) {
	var b bytes.Buffer
	err := RenderApplication(&b, "devzone-workspace", "workspace", "devzone-workspace", "https://x/devzone.git", "main", "charts/devzone-workspace", []string{"image.tag=latest", "image.pullPolicy=Always"}, "")
	if err != nil {
		t.Fatal(err)
	}
	out := b.String()
	if !strings.Contains(out, "    helm:\n      parameters:\n") {
		t.Fatalf("missing helm parameters:\n%s", out)
	}
	if !strings.Contains(out, "- name: image.tag\n          value: \"latest\"\n") {
		t.Fatalf("missing image.tag:\n%s", out)
	}
	if !strings.Contains(out, "- name: image.pullPolicy\n          value: \"Always\"\n") {
		t.Fatalf("missing image.pullPolicy:\n%s", out)
	}
	var b2 bytes.Buffer
	err = RenderApplication(&b2, "devzone-workspace", "workspace", "devzone-workspace", "https://x/devzone.git", "main", "charts/devzone-workspace", []string{"image.tag"}, "")
	if err == nil || !strings.Contains(err.Error(), "parameter without value: image.tag") {
		t.Fatalf("got err=%v", err)
	}
}

func TestRenderApplicationValidation(t *testing.T) {
	var b bytes.Buffer
	if err := RenderApplication(&b, "x", "other", "ns", "https://x", "r", "p", nil, ""); err == nil || !strings.Contains(err.Error(), "unknown kind: other") {
		t.Fatalf("err=%v", err)
	}
	if err := RenderApplication(&b, "Bad Name", "project", "ns", "https://x", "r", "p", nil, ""); err == nil || !strings.Contains(err.Error(), "invalid name") {
		t.Fatalf("err=%v", err)
	}
	if err := RenderApplication(&b, "-x", "project", "ns", "https://x", "r", "p", nil, ""); err == nil || !strings.Contains(err.Error(), "invalid name") {
		t.Fatalf("err=%v", err)
	}
	if err := RenderApplication(&b, "x", "project", "", "https://x", "r", "p", nil, ""); err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("err=%v", err)
	}
}
