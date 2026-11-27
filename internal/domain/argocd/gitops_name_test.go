package argocd

import "testing"

// TestGitopsRepoNameValue checks the GitOps repository name follows
// DEVZONE_GITOPS_REPO_NAME, as the shell did for both the repository and the
// repository Secret. Why: a Secret named after the default while the
// repository was created under another name would point Argo CD at nothing.
func TestGitopsRepoNameValue(t *testing.T) {
	t.Setenv("DEVZONE_GITOPS_REPO_NAME", "")
	if got := gitopsRepoNameValue(); got != "devzone-argocd" {
		t.Fatalf("default = %q", got)
	}
	t.Setenv("DEVZONE_GITOPS_REPO_NAME", "mine")
	if got := gitopsRepoNameValue(); got != "mine" {
		t.Fatalf("override = %q", got)
	}
}
