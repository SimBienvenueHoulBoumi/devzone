package workspace

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// IdentityFunc returns the value of a git setting of the workstation (user.name
// or user.email), or "" when it is not set. Clone takes it as a parameter, so
// that tests need no git.
type IdentityFunc func(key string) string

// cloneUsage is the message of "devzone workspace clone" without url, as
// workspace_clone prints it in manage/scripts/workspace-clone.sh.
const cloneUsage = "✖ usage: devzone workspace clone <url> [<name>]"

// Identity returns the value of the git setting key on the workstation, as
// "git config --get key" prints it, or "" when it is not set. The errors of git
// are not shown, as in the bash entry point.
func Identity(key string) string {
	out, _ := exec.Command("git", "config", "--get", key).Output()
	return strings.TrimRight(string(out), "\n")
}

// Clone clones the git repository url into the projects folder of the pod, under
// name, or under the name taken from url when name is "", as workspace_clone in
// manage/scripts/workspace-clone.sh does. cloneScript runs in the pod, with the
// git name and email given by identity. It returns 1 (message on errOut) when url
// is "" or the folder name is not valid. Otherwise it returns the status of the
// kubectl exec, which is the status of the pod script (3 when the folder holds
// another project), or 127 when kubectl cannot start.
func Clone(r Runner, identity IdentityFunc, url, name string, out, errOut io.Writer) int {
	if url == "" {
		fmt.Fprintln(errOut, cloneUsage)
		return 1
	}
	if name == "" {
		name = cloneName(url)
	}
	if !validFolderName(name) {
		fmt.Fprintf(errOut, "✖ invalid folder name: %s (letters, digits, . _ - only)\n", orEmpty(name))
		return 1
	}
	args := append(contextFlag(r), "exec", "-i", pod, "--namespace", namespace, "-c", container, "--",
		"bash", "-s", "--", projectsDir+"/"+name, url, identity("user.name"), identity("user.email"))
	status, err := r.Kubectl(args, strings.NewReader(cloneScript), out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start kubectl: %v\n", err)
		return notStarted
	}
	return status
}

// cloneName returns the folder name taken from a url: the last path segment
// without a trailing ".git" (and without a trailing "/"). The part after the last
// ":" is kept too, so that "git@host:acme/mine.git" gives "mine".
func cloneName(url string) string {
	u := strings.TrimSuffix(url, "/")
	if i := strings.LastIndex(u, "/"); i >= 0 {
		u = u[i+1:]
	}
	if i := strings.LastIndex(u, ":"); i >= 0 {
		u = u[i+1:]
	}
	return strings.TrimSuffix(u, ".git")
}

// validFolderName reports whether name may be a folder of the projects folder:
// not empty, not "." or "..", not starting with "-", and made of letters, digits,
// "." "_" and "-" only, as the case of workspace_clone in manage/scripts/workspace-clone.sh.
func validFolderName(name string) bool {
	if name == "" || name == "." || name == ".." || strings.HasPrefix(name, "-") {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !letter && c != '.' && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

// orEmpty returns s, or "empty" when s is "", as the message of an invalid name shows it
func orEmpty(s string) string {
	if s == "" {
		return "empty"
	}
	return s
}
