package workspace

import (
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// argocdNamespace is the namespace of Argo CD in the cluster, as ARGOCD_NS in
// argocd-workspace.sh.
const argocdNamespace = config.NamespaceArgoCD

// argocdWanted reports whether the workspace wants Argo CD: the key argocd of
// the modules file must not be exactly "off". An absent key or any other value
// (including "false") keeps it wanted, as argocd_wanted in
// argocd-workspace.sh decides it from state_read. It needs no cluster.
func argocdWanted(modules string) bool {
	return readModulesKey(modules, "argocd") != "off"
}

// argocdInstalled reports whether the namespace of Argo CD exists: the call
// "kubectl get namespace devzone-argocd", with the services context flag when
// kubeconfig declares it, must succeed. Output and errors of kubectl are
// ignored, and a kubectl that cannot start counts as not installed, like
// argocd_installed in argocd-workspace.sh.
func argocdInstalled(r Runner) bool {
	status, err := r.Kubectl(append(contextFlag(r), "get", "namespace", argocdNamespace),
		nil, io.Discard, io.Discard)
	return err == nil && status == 0
}

// argocdActive reports whether Argo CD is wanted and installed, as
// argocd_active in argocd-workspace.sh: it is then driven through Applications
// instead of helm direct. The && of the shell is kept: when argocd is off,
// wanted is false and kubectl is never called.
func argocdActive(r Runner, modules string) bool {
	return argocdWanted(modules) && argocdInstalled(r)
}

// argocdQuantityKi converts a Kubernetes memory quantity to Ki, as
// argocd_quantity_ki in argocd-workspace.sh tries the suffixes in this order:
// Ki, Mi, Gi, Ti, K or k, M, G, then a bare number of bytes. Divisions are
// integer divisions, so a K, M or G quantity loses its remainder. An empty
// value, an unknown suffix (Ei, Pi, ...) or a bare value that is not only
// digits gives 0. Accepted difference: the shell evaluates the number with
// bash arithmetic, where a non-numeric text is 0 and a decimal such as 1.5Gi
// makes the function fail; the real memory quantities of the nodes are
// integers (16384Mi, 8049188Ki), so Go reads an integer and returns 0 for
// everything else, decimals included.
func argocdQuantityKi(q string) int64 {
	if n, ok := argocdQuantityNumber(q, "Ki"); ok {
		return n
	}
	if n, ok := argocdQuantityNumber(q, "Mi"); ok {
		return n * 1024
	}
	if n, ok := argocdQuantityNumber(q, "Gi"); ok {
		return n * 1024 * 1024
	}
	if n, ok := argocdQuantityNumber(q, "Ti"); ok {
		return n * 1024 * 1024 * 1024
	}
	if n, ok := argocdQuantityNumber(q, "K"); ok {
		return n * 1000 / 1024
	}
	if n, ok := argocdQuantityNumber(q, "k"); ok {
		return n * 1000 / 1024
	}
	if n, ok := argocdQuantityNumber(q, "M"); ok {
		return n * 1000 * 1000 / 1024
	}
	if n, ok := argocdQuantityNumber(q, "G"); ok {
		return n * 1000 * 1000 * 1000 / 1024
	}
	if q == "" || !argocdDigits(q) {
		return 0
	}
	n, err := strconv.ParseInt(q, 10, 64)
	if err != nil {
		return 0
	}
	return n / 1024
}

// argocdQuantityNumber returns the integer that precedes suffix in q, and
// whether q ends with suffix and that text is an integer.
func argocdQuantityNumber(q, suffix string) (int64, bool) {
	if !strings.HasSuffix(q, suffix) {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSuffix(q, suffix), 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// argocdDigits reports whether s is made only of decimal digits (and is not
// empty), like the *[!0-9]* test of argocd_quantity_ki.
func argocdDigits(s string) bool {
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

// argocdRevision returns the Git revision of the devzone charts:
// DEVZONE_ARGOCD_REVISION when it is not empty, otherwise the tag of the
// version of package.json, as argocd_revision in argocd-workspace.sh. The
// version is read line by line, not as JSON: the first line matching
// .*"version": *"([^"]*)".* wins, and on that line the greedy .* keeps the
// last occurrence. An empty version or 0.0.0 gives an empty string (a
// development clone has no chart in Git); any other version is prefixed with
// v. A missing file gives an empty string.
func argocdRevision(root string) string {
	if revision := os.Getenv("DEVZONE_ARGOCD_REVISION"); revision != "" {
		return revision
	}
	data, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		match := argocdVersionPattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		version := match[1]
		if version == "" || version == "0.0.0" {
			return ""
		}
		return "v" + version
	}
	return ""
}

// argocdVersionPattern is the sed expression of argocd_revision, greedy .*
// included, so that the last "version": "..." of a line is kept.
var argocdVersionPattern = regexp.MustCompile(`.*"version": *"([^"]*)".*`)
