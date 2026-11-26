package gitlab

import (
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	neturl "net/url"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitopsWriteApp writes the Application manifest into the GitOps repository
// designated in .argocd.conf, like gitops_apply_application of gitops.sh:
// GitHub through the gh API (gitops_put), GitLab through its files endpoint
// (gitops-gitlab.sh).
func (r *run) gitopsWriteApp(name, manifest, message string) error {
	if r.gitopsProvider() == "gitlab" {
		return r.gitopsWriteFileGitLab("apps/"+name+".yaml", manifest, message)
	}
	return r.gitopsWriteFileGitHub(name, manifest, message)
}

// gitopsWriteFileGitHub writes a file of the GitOps repository through the
// GitHub API of gh (gitops_put of gitops.sh): PUT when the file exists, POST
// when it is new.
func (r *run) gitopsWriteFileGitHub(name, content, message string) error {
	slug := strings.TrimSuffix(strings.TrimPrefix(r.gitopsRepo(), "https://github.com/"), ".git")
	path := neturl.PathEscape("apps/" + name + ".yaml")
	sha := ""
	if res, err := r.runner().Run(r.ctx, "gh",
		[]string{"api", "repos/" + slug + "/contents/" + path, "--jq", ".sha"}, exec.Opts{}); err == nil {
		if s := strings.TrimSpace(string(res.Stdout)); isHex(s) {
			sha = s
		}
	}
	all := []string{"api"}
	if sha != "" {
		all = append(all, "-X", "PUT")
	} else {
		all = append(all, "-X", "POST")
	}
	all = append(all, "repos/"+slug+"/contents/"+path,
		"-f", "message="+message,
		"-f", "content="+base64.StdEncoding.EncodeToString([]byte(content)))
	if sha != "" {
		all = append(all, "-f", "sha="+sha)
	}
	_, err := r.runner().Run(r.ctx, "gh", all, exec.Opts{})
	return err
}

// gitopsWriteFileGitLab writes a file of the GitLab GitOps repository of Argo
// CD (gitops-gitlab.sh gitlab_gitops_put: files endpoint, no clone); the same
// blob is not written again.
func (r *run) gitopsWriteFileGitLab(path, content, message string) error {
	token, ok := r.readSecret(r.rootTokenFile())
	if !ok {
		return fmt.Errorf("root token missing: devzone enable gitlab")
	}
	id := jsonField(r.apiGet(token, "/projects/"+neturl.PathEscape("devzone/devzone-argocd")), "id")
	if id == "" {
		return fmt.Errorf("project devzone/devzone-argocd missing: devzone argocd init --gitlab")
	}
	file := neturl.PathEscape(path)
	sha := ""
	if res := r.apiGet(token, "/projects/"+id+"/repository/files/"+file+"?ref=main"); jsonField(res, "blob_id") != "" {
		sha = jsonField(res, "blob_id")
		if sha == gitBlobSHA(content) {
			return nil
		}
	}
	form := neturl.Values{}
	form.Set("branch", "main")
	form.Set("encoding", "base64")
	form.Set("content", base64.StdEncoding.EncodeToString([]byte(content)))
	form.Set("commit_message", message)
	method := "POST"
	if sha != "" {
		method = "PUT"
		form.Set("sha", sha)
	}
	_, err := r.apiForm(token, method, "/projects/"+id+"/repository/files/"+file, form.Encode())
	return err
}

// gitBlobSHA returns the git blob id of content, like git hash-object.
func gitBlobSHA(content string) string {
	h := sha1.New()
	_, _ = fmt.Fprintf(h, "blob %d\x00%s", len(content), content)
	return fmt.Sprintf("%x", h.Sum(nil))
}

// isHex reports whether s is non-empty and made only of hexadecimal digits.
func isHex(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return false
		}
	}
	return true
}
