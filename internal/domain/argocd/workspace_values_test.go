package argocd

import (
	"encoding/base64"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestEnsureWorkspaceValuesCreatesThenKeepsUserFile checks that a missing
// values file is written once, and that a second start leaves a user edit
// untouched: only the blob sha is read on the second call.
func TestEnsureWorkspaceValuesCreatesThenKeepsUserFile(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	m := newFixtureModule(t, f)
	shaArgs := []string{"api", "repos/tester/devzone-argocd/contents/values/devzone-workspace.yaml", "--jq", ".sha"}
	f.r.On("gh", shaArgs, fexec.Result{Code: 1, Stdout: []byte(`{"message":"Not Found","status":"404"}`)})
	writeArgs := []string{"api", "-X", "PUT", "repos/tester/devzone-argocd/contents/values/devzone-workspace.yaml",
		"-f", "message=devzone: values devzone-workspace",
		"-f", "content=" + base64.StdEncoding.EncodeToString([]byte(workspaceValuesContent))}
	f.r.On("gh", writeArgs, fexec.Result{})
	if code := m.ensureWorkspaceValuesFile(); code != 0 {
		t.Fatalf("first ensure: code=%d err=%q", code, f.err.String())
	}
	if callIndex(f.r.Calls(), "gh", writeArgs...) < 0 {
		t.Fatalf("values file was not created: %v", f.r.Calls())
	}
	for _, want := range []string{
		"# livenessProbe:\n#   thresholdPercent: 85",
		"#   periodSeconds: 60",
		"#   failureThreshold: 5",
		"#   initialDelaySeconds: 120",
		"# resources:\n#   limits:\n#     memory: 8Gi",
		"#   requests:\n#     memory: 4Gi",
	} {
		if !strings.Contains(workspaceValuesContent, want) {
			t.Fatalf("template misses %q", want)
		}
	}

	userContent := strings.Replace(workspaceValuesContent,
		"# livenessProbe.thresholdPercent: 85", "livenessProbe.thresholdPercent: 90", 1)
	f.r.On("gh", shaArgs, fexec.Result{Stdout: []byte(gitBlobSHA([]byte(userContent)) + "\n")})
	before := len(f.r.Calls())
	if code := m.ensureWorkspaceValuesFile(); code != 0 {
		t.Fatalf("second ensure: code=%d err=%q", code, f.err.String())
	}
	calls := f.r.Calls()[before:]
	if len(calls) != 1 || callIndex(calls, "gh", shaArgs...) != 0 {
		t.Fatalf("second ensure did more than read the sha: %v", calls)
	}
}

// TestEnsureWorkspaceValuesWithoutGitOpsDoesNothing checks that no host call
// is made when the workstation has no designated GitOps repository.
func TestEnsureWorkspaceValuesWithoutGitOpsDoesNothing(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = none\n")
	if code := newFixtureModule(t, f).ensureWorkspaceValuesFile(); code != 0 {
		t.Fatalf("ensure without GitOps: code=%d err=%q", code, f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls without GitOps: %v", f.r.Calls())
	}
}
