package workspace

import (
	"bytes"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
)

// guardRefused is the status of copyGuardScript when the pod folder is a clone
// of another remote.
const guardRefused = 3

// OriginFunc returns the URL of the origin remote of a folder, or "" when there
// is none. CopyTo takes it as a parameter, so that tests need no git.
type OriginFunc func(folder string) string

// Origin returns the URL of the origin remote of folder, as
// "git -C folder remote get-url origin" prints it, or "" when the folder is not
// a git clone or has no origin. The errors of git are not shown.
func Origin(folder string) string {
	out, _ := exec.Command("git", "-C", folder, "remote", "get-url", "origin").Output()
	return strings.TrimRight(string(out), "\n")
}

// copyGuardScript runs in the pod (bash -s, with the pod folder and the remote of
// the workstation folder as $1 and $2). It prints the remote of the pod folder
// and exits 3 when that folder is a clone of another remote. Same script as
// workspace_copy_pod_script in manage/scripts/workspace-copies.sh.
const copyGuardScript = `[ -e "$1/.git" ] || exit 0
r="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
n() { local u="${1%/}"; echo "${u%.git}"; }
[ "$(n "$r")" = "$(n "$2")" ] && exit 0
echo "${r:-none}"
exit 3
`

// copyGuard reports whether copy-to may copy folder over the pod. It returns
// false, with the message on errOut, when the pod holds a clone of another
// remote: such a clone is never overwritten. A pod that cannot be reached, or a
// kubectl that fails in another way, lets the copy go on, as in bash.
func copyGuard(r Runner, origin OriginFunc, folder string, errOut io.Writer) bool {
	mine := origin(folder)
	base := filepath.Base(folder)
	args := append(contextFlag(r), "exec", "-i", pod, "--namespace", namespace,
		"-c", container, "--", "bash", "-s", "--", projectsDir+"/"+base, mine)
	var other bytes.Buffer
	status, err := r.Kubectl(args, strings.NewReader(copyGuardScript), &other, io.Discard)
	if err != nil || status != guardRefused {
		return true
	}
	here := mine
	if here == "" {
		here = "none"
	}
	fmt.Fprintf(errOut, "✖ %s/%s in the pod is a git clone with another remote (%s, here: %s); not overwritten\n",
		projectsDir, base, strings.TrimRight(other.String(), "\n"), here)
	fmt.Fprintln(errOut, "  work in that clone (devzone workspace clone), or remove it first")
	return false
}
