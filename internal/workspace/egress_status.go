package workspace

import (
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// egressStatus writes the mode, readiness, number of allowed domains and the
// domains contacted in the access log, as egress_status does. It returns 1 when
// the cluster is not ready, 0 otherwise.
func egressStatus(k kubeEnv, out, errOut io.Writer) int {
	if reason, ok := k.ready(true); !ok {
		fmt.Fprintln(errOut, reason)
		return 1
	}
	r := k.runner
	flag := contextFlag(r)
	mode := kubectlText(r, append(flag, "-n", namespace, "get", "service", "egress-proxy",
		"-o", `jsonpath={.metadata.labels.devzone\.io/egress-mode}`))
	if mode == "" {
		fmt.Fprintln(out, "egress off")
		return 0
	}
	ready := kubectlText(r, append(flag, "-n", namespace, "get", "deployment", "devzone-workspace-egress-proxy",
		"-o", `jsonpath={.status.readyReplicas}`))
	if replicas, err := strconv.Atoi(ready); err == nil && replicas >= 1 {
		ready = "ready"
	} else {
		ready = "not ready"
	}
	config := kubectlText(r, append(flag, "-n", namespace, "get", "configmap", "devzone-workspace-egress-proxy",
		"-o", `jsonpath={.data.squid\.conf}`))
	count := 0
	for _, line := range strings.Split(config, "\n") {
		if strings.Contains(line, "acl allowed dstdomain ") {
			count++
		}
	}
	fmt.Fprintf(out, "egress %s, proxy %s, allowed domains: %d\n", mode, ready, count)
	logs := kubectlText(r, append(flag, "-n", namespace, "logs", "deployment/devzone-workspace-egress-proxy",
		"-c", "access-log", "--tail=2000"))
	table := accessTable(logs, mode)
	if table == "" {
		fmt.Fprintln(out, "  no domain contacted in the recent log")
		return 0
	}
	fmt.Fprintf(out, "  %-40s %6s  %s\n", "domain", "accesses", "state")
	fmt.Fprint(out, table)
	return 0
}

// kubectlText runs a read-only kubectl query and returns its standard output,
// ignoring failures as the shell does with "2>/dev/null || true".
func kubectlText(r Runner, args []string) string {
	var out strings.Builder
	_, _ = r.Kubectl(args, nil, &out, io.Discard)
	return out.String()
}

// accessTable parses the squid native access log as the awk of egress_status:
// only CONNECT lines count, the port is removed from the host, and a denied
// access marks the host refused. The rows are sorted by host.
func accessTable(logs, mode string) string {
	type domain struct {
		hits    int
		refused bool
	}
	seen := map[string]*domain{}
	for _, line := range strings.Split(logs, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 7 || fields[5] != "CONNECT" {
			continue
		}
		host := fields[6]
		if i := strings.LastIndex(host, ":"); i >= 0 && strings.Trim(host[i+1:], "0123456789") == "" {
			host = host[:i]
		}
		entry := seen[host]
		if entry == nil {
			entry = &domain{}
			seen[host] = entry
		}
		entry.hits++
		if strings.Contains(fields[3], "DENIED") {
			entry.refused = true
		}
	}
	hosts := make([]string, 0, len(seen))
	for host := range seen {
		hosts = append(hosts, host)
	}
	sort.Strings(hosts)
	var b strings.Builder
	for _, host := range hosts {
		state := "allowed"
		if seen[host].refused {
			state = "refused"
		} else if mode == "observation" {
			state = "observed"
		}
		fmt.Fprintf(&b, "  %-40s %6d  %s\n", host, seen[host].hits, state)
	}
	return b.String()
}
