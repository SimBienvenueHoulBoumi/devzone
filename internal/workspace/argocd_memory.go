package workspace

import (
	"bytes"
	"fmt"
	"io"
	"strings"
)

// argocdMinMemoryKi is the minimum of allocatable memory for Argo CD: 1 Gi, as
// ARGOCD_MIN_MEMORY_KI in argocd-workspace.sh.
const argocdMinMemoryKi = 1048576

// argocdNodesJsonpath is the -o argument of the kubectl call of the memory
// check: the jsonpath that prints the allocatable memory of every node, one
// quantity per node, as the shell jsonpath of argocd_memory_ok.
const argocdNodesJsonpath = `jsonpath={range .items[*]}{.status.allocatable.memory}{"\n"}{end}`

// argocdMemoryOK reports whether the cluster can host Argo CD: it sums the
// allocatable memory of the nodes, in Ki, with argocdQuantityKi, and refuses
// the installation (status 2) under 1 Gi, writing the reason on errOut, as
// argocd_memory_ok of argocd-workspace.sh. Why: an installation on a cluster
// too small cannot run, and the user is told to enlarge the cluster before
// retrying. The shell message ends with "enlarge the cluster (<product> ->
// Settings -> Resources), then:" while the Go writes "enlarge the memory of the
// cluster, then:"; the product name is retired by another ticket, so the Go does
// not use it.
func argocdMemoryOK(r Runner, errOut io.Writer) int {
	var out bytes.Buffer
	status, err := r.Kubectl(append(contextFlag(r), "get", "nodes", "-o", argocdNodesJsonpath),
		nil, &out, io.Discard)
	lines := ""
	if err == nil && status == 0 {
		lines = strings.TrimRight(out.String(), "\n")
	}
	if lines == "" {
		fmt.Fprintf(errOut, "✖ argocd: cluster unreachable or nodes unreadable (kubectl config get-contexts)\n")
		return 2
	}
	total := int64(0)
	for _, line := range strings.Split(lines, "\n") {
		if line == "" {
			continue
		}
		total += argocdQuantityKi(line)
	}
	if total < argocdMinMemoryKi {
		fmt.Fprintf(errOut, "✖ argocd: at least 1 Gi of allocatable memory is needed in the cluster (available: %d Mi); enlarge the memory of the cluster, then: devzone workspace services enable argocd\n", total/1024)
		return 2
	}
	return 0
}
