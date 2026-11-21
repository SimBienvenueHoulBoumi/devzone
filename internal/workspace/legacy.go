package workspace

import (
	"bytes"
	"fmt"
	"io"
	"strings"
)

// podScript runs in the pod (bash -s with the projects folder as $1). It prints
// the legacy copies, one folder name per line: a copy is legacy when its .git
// file points to a git folder missing from the pod. Same script as
// workspace_legacy_pod_script in manage/scripts/workspace-copies.sh.
const podScript = `broken() {
    local g
    [ -f "$1/.git" ] || return 1
    g="$(sed -n 's/^gitdir: *//p' "$1/.git" | head -1)"
    [ -n "$g" ] && [ ! -e "$g" ]
}
cd "$1" || exit 0
if broken repogarde; then echo repogarde; fi
for d in wt/*; do
    if broken "$d"; then echo wt; break; fi
done
`

// reportLegacyCopies writes the legacy copies still in the pod, with the
// commands that remove them. Nothing is written when the pod cannot be reached:
// the check is informative only, as in the bash entry point.
func reportLegacyCopies(r Runner, out io.Writer) {
	args := append(contextFlag(r), "exec", "-i", pod, "--namespace", namespace,
		"-c", container, "--", "bash", "-s", "--", projectsDir)
	var found bytes.Buffer
	status, err := r.Kubectl(args, strings.NewReader(podScript), &found, io.Discard)
	if err != nil || status != 0 {
		return
	}
	folders := strings.Fields(found.String())
	if len(folders) > 0 {
		fmt.Fprint(out, legacyMessage(folders))
	}
}

// legacyMessage returns the warning for the legacy copies, given as folder names
// of the projects folder, with the commands that save and remove them.
func legacyMessage(folders []string) string {
	var b strings.Builder
	b.WriteString("⚠ legacy copies in the pod (their .git points outside the pod):")
	for _, folder := range folders {
		b.WriteString(" " + projectsDir + "/" + folder)
	}
	b.WriteString("\n")
	b.WriteString("  1. save what you need: devzone workspace copy-from <folder>\n")
	b.WriteString("  2. remove them from the pod shell (devzone workspace shell), one folder at a time:\n")
	for _, folder := range folders {
		b.WriteString("       rm -rf " + projectsDir + "/" + folder + "\n")
	}
	return b.String()
}
