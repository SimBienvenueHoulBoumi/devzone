package gitlab

import (
	"context"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestApplicationManifestIsSafe checks the Application fields that protect
// an adopted GitLab: Helm releaseName field, no cascade finalizer, no
// automated sync and real YAML line breaks.
func TestApplicationManifestIsSafe(t *testing.T) {
	manifest := applicationManifest("devzone-gitlab", "https://example.invalid/devzone.git", "v1.2.3",
		"gitlab-runner.gitlabUrl=http://gitlab-webservice-default.devzone-gitlab.svc:8181")
	release := strings.Index(manifest, "      releaseName: gitlab")
	params := strings.Index(manifest, "      parameters:")
	if release < 0 || params < 0 || release > params {
		t.Fatalf("releaseName must be a spec.source.helm field before parameters:\n%s", manifest)
	}
	for _, forbidden := range []string{
		"finalizers:", "resources-finalizer.argocd.argoproj.io", "automated:",
		"prune: true", "selfHeal: true", "- name: releaseName", `\n`,
	} {
		if strings.Contains(manifest, forbidden) {
			t.Errorf("manifest contains %q:\n%s", forbidden, manifest)
		}
	}
	for _, want := range []string{
		"        - name: gitlab-runner.gitlabUrl", "      - PruneLast=true",
		"  syncPolicy:\n    syncOptions:",
	} {
		if !strings.Contains(manifest, want) {
			t.Errorf("manifest lacks %q:\n%s", want, manifest)
		}
	}
}

// TestApplicationReleaseNameFallsBack checks that an absent or empty release
// name on an existing Application gives the default "gitlab".
func TestApplicationReleaseNameFallsBack(t *testing.T) {
	for _, tc := range []struct {
		name string
		res  exec.Result
	}{
		{"absent", exec.Result{Code: 1}},
		{"empty", exec.Result{Stdout: []byte("\n")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "get",
				"application.argoproj.io", "devzone-gitlab", "-o", "jsonpath={.spec.source.helm.releaseName}"}, tc.res)
			r := newRun(context.Background(), f.opts())
			if got := r.applicationReleaseName(); got != "gitlab" {
				t.Errorf("release name = %q, want gitlab", got)
			}
		})
	}
}

// TestApplicationApplyReusesExistingReleaseName checks that an existing
// Application keeps its Helm release name when the manifest is rewritten.
func TestApplicationApplyReusesExistingReleaseName(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "get",
		"application.argoproj.io", "devzone-gitlab", "-o", "jsonpath={.spec.source.helm.releaseName}"},
		exec.Result{Stdout: []byte("autre\n")})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "apply", "-f", "-"},
		exec.Result{})
	r := newRun(context.Background(), f.opts())
	if code := r.applicationApply("v1.2.3"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	manifest := ""
	for _, call := range f.r.Calls() {
		if call.Name != "kubectl" || call.Opts.Stdin == nil ||
			strings.Join(call.Args, " ") != "--context devzone -n devzone-argocd apply -f -" {
			continue
		}
		data, err := io.ReadAll(call.Opts.Stdin)
		if err != nil {
			t.Fatal(err)
		}
		manifest = string(data)
	}
	if !strings.Contains(manifest, "      releaseName: autre") {
		t.Errorf("existing release name was not reused:\n%s", manifest)
	}
	if strings.Contains(manifest, "- name: releaseName") {
		t.Errorf("releaseName was written as a parameter:\n%s", manifest)
	}
}
