package gitlab

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// runner returns the runner of the run: the one of the options, else the
// package default, else the real process.
func (r *run) runner() exec.Runner {
	if r.opts.Runner != nil {
		return r.opts.Runner
	}
	if kube.DefaultRunner != nil {
		return kube.DefaultRunner
	}
	return exec.ExecRunner{}
}

// clusterSaved returns the context chosen in the state of the instance, like
// cluster_saved: the last line cluster= of the state file.
func (r *run) clusterSaved() string {
	data, err := os.ReadFile(r.state)
	if err != nil {
		return ""
	}
	saved := ""
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, "cluster="); ok {
			saved = v
		}
	}
	return saved
}

// accountContext returns the administrator context of the instance: the chosen
// cluster when there is one, else the current context of kubectl.
func (r *run) accountContext() string {
	if ctx := r.clusterSaved(); ctx != "" {
		return ctx
	}
	res, err := r.runner().Run(r.ctx, "kubectl", []string{"config", "current-context"}, exec.Opts{})
	if err == nil && res.Code == 0 {
		return strings.TrimSpace(string(res.Stdout))
	}
	return ""
}

// adminKubeconfig returns the kubeconfig holding the administrator context,
// like AdminKubeconfig of the platform package.
func (r *run) adminKubeconfig(ctx string) string {
	return kube.AdminKubeconfig(ctx)
}

// quantityKi converts a Kubernetes memory quantity into Ki (the shell function
// quantity_ki of memory.sh); 0 for empty or non-numeric input.
func quantityKi(q string) int64 {
	if q == "" {
		return 0
	}
	var number string
	var factor, divisor int64 = 1, 1
	switch {
	case strings.HasSuffix(q, "Ki"):
		number = q[:len(q)-2]
	case strings.HasSuffix(q, "Mi"):
		number, factor = q[:len(q)-2], 1024
	case strings.HasSuffix(q, "Gi"):
		number, factor = q[:len(q)-2], 1024*1024
	case strings.HasSuffix(q, "Ti"):
		number, factor = q[:len(q)-2], 1024*1024*1024
	case strings.HasSuffix(q, "K"), strings.HasSuffix(q, "k"):
		number, factor, divisor = q[:len(q)-1], 1000, 1024
	case strings.HasSuffix(q, "M"):
		number, factor, divisor = q[:len(q)-1], 1000*1000, 1024
	case strings.HasSuffix(q, "G"):
		number, factor, divisor = q[:len(q)-1], 1000*1000*1000, 1024
	default:
		if !isDigits(q) {
			return 0
		}
		number, divisor = q, 1024
	}
	n, err := strconv.ParseInt(number, 10, 64)
	if err != nil {
		return 0
	}
	return n * factor / divisor
}

// isDigits reports whether s is non-empty and made only of digits.
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// memoryResult is the answer of memoryClusterKi: the memory in Ki and the rule.
type memoryResult struct {
	Ki   int64
	Rule string // "maximum" or "sum"
}

// memoryClusterKi reads the allocatable memory of the nodes of the services
// cluster, in Ki, like memory_cluster_ki of memory.sh: one line per node with
// its providerID and memory; every kind node means the maximum, otherwise the
// sum. ok=false when the nodes cannot be read.
func (r *run) memoryClusterKi() (memoryResult, bool) {
	ctx := r.accountContext()
	res, err := r.runner().Run(r.ctx, "kubectl",
		[]string{"--kubeconfig=" + r.adminKubeconfig(ctx), "--context", ctx, "get", "nodes",
			"-o", "jsonpath={range .items[*]}{.spec.providerID}{\"|\"}{.status.allocatable.memory}{\"\\n\"}{end}"},
		exec.Opts{})
	if err != nil || res.Code != 0 || len(res.Stdout) == 0 {
		return memoryResult{}, false
	}
	var total, max int64
	n := 0
	allKind := true
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if line == "" {
			continue
		}
		providerID, memory := "", line
		if i := strings.IndexByte(line, '|'); i >= 0 {
			providerID, memory = line[:i], line[i+1:]
		}
		node := quantityKi(memory)
		total += node
		if node > max {
			max = node
		}
		if !strings.HasPrefix(providerID, "kind://") {
			allKind = false
		}
		n++
	}
	if n > 0 && allKind {
		return memoryResult{Ki: max, Rule: "maximum"}, true
	}
	return memoryResult{Ki: total, Rule: "sum"}, true
}

// checkModuleMemory refuses the installation of module when the allocatable
// memory of the services cluster is below minimumGi, like check_module_memory
// of memory.sh: 2 on refusal or unreachable cluster, 0 otherwise.
func (r *run) checkModuleMemory(module string, minimumGi int, hint string) int {
	mem, ok := r.memoryClusterKi()
	if !ok {
		fmt.Fprintf(r.errOut(), "devzone : %s : services cluster unreachable: devzone cluster\n", module)
		return 2
	}
	precision := ""
	if mem.Rule == "maximum" {
		precision = " (memory of a single node: kind cluster, shared VM)"
	}
	if mem.Ki < int64(minimumGi)*1048576 {
		extra := ""
		if hint != "" {
			extra = " ; hint: " + hint
		}
		fmt.Fprintf(r.errOut(), "devzone : %s : at least %d GiB of allocatable memory is needed in the cluster (available: %d GiB)%s ; enlarge the cluster (Docker Desktop → Settings → Resources) then retry: devzone enable %s%s\n",
			module, minimumGi, mem.Ki/1048576, precision, module, extra)
		return 2
	}
	return 0
}
