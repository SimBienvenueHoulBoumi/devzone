package workspace

import (
	"fmt"
	"io"
)

// ServicesStatus writes one line per service of the cluster, in the order
// gitlab, postgres, mysql, argocd: "  ✔ s installed (namespace ns): devzone
// workspace services disable s" when the call "kubectl [--context devzone] get
// namespace ns" succeeds, "  ○ s not installed: devzone workspace services
// enable s" otherwise (also when kubectl cannot start: all the lines are then
// "not installed"). It exists to show at once which services of the cluster
// are installed, as services_status in
// manage/scripts/workspace/workspace services (Go). The kubectl calls print
// nothing: the lines carry the answer; the status is 0.
func ServicesStatus(r Runner, out io.Writer) int {
	for _, s := range []struct {
		name      string
		namespace string
	}{
		{"gitlab", "devzone-gitlab"},
		{"postgres", "devzone-postgres"},
		{"mysql", "devzone-mysql"},
		{"argocd", "devzone-argocd"},
	} {
		status, err := r.Kubectl(append(contextFlag(r), "get", "namespace", s.namespace),
			nil, io.Discard, io.Discard)
		if err != nil || status != 0 {
			fmt.Fprintf(out, "  ○ %s not installed: devzone workspace services enable %s\n",
				s.name, s.name)
			continue
		}
		fmt.Fprintf(out, "  ✔ %s installed (namespace %s): devzone workspace services disable %s\n",
			s.name, s.namespace, s.name)
	}
	return 0
}
