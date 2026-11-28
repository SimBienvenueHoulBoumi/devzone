package mysql

import (
	"context"
	"fmt"
	"strings"
)

const volumeJSONPath = `{range .items[*]}{.metadata.name}{"\n"}{end}`
const claimJSONPath = `{.spec.volumeClaimTemplates[0].metadata.name}`

// Volume lists the PVCs, selects one for reinstallation, or deletes one.
func Volume(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	name, remove, yes := "", false, false
	for _, arg := range args {
		switch arg {
		case "--delete":
			remove = true
		case "--yes":
			yes = true
		default:
			name = arg
		}
	}
	if remove {
		return e.deleteVolume(name, yes)
	}
	if name == "" {
		e.listVolumes()
		return 0
	}
	if _, ok := e.moduleContext(); !ok {
		return 2
	}
	if !e.installed(e.activeAdminContext()) {
		return e.fail("module disabled: devzone enable mysql")
	}
	return e.installClaim(e.cluster(), ns, strings.TrimSuffix(name, "-mysql-0"))
}

// deleteVolume removes an unmounted PVC after terminal confirmation.
func (e *env) deleteVolume(name string, yes bool) int {
	if name == "" {
		return e.fail("volume --delete: missing name")
	}
	pvc := name
	if !strings.HasSuffix(pvc, "-mysql-0") {
		pvc += "-mysql-0"
	}
	if strings.TrimSuffix(pvc, "-mysql-0") == e.claimMounted(ns) {
		return e.fail("mounted volume, deletion refused: %s", name)
	}
	if !yes {
		if !e.interactive() {
			return e.fail("confirmation needs a terminal: devzone mysql volume --delete %s --yes", name)
		}
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "Delete volume %s? [y/N] ", pvc)
		}
		switch e.answer() {
		case "y", "Y", "yes":
		default:
			e.line("Aborted: nothing was deleted.")
			return 0
		}
	}
	res, err := e.exec("kubectl", e.kubectlArgs(ns, "delete", "pvc", pvc), nil)
	if err != nil || res.Code != 0 {
		e.showErr(res)
		return 1
	}
	e.line("✔ volume %s deleted", pvc)
	return 0
}

// listVolumes prints the PVCs with a marker on the mounted one.
func (e *env) listVolumes() {
	mounted := e.claimMounted(ns) + "-mysql-0"
	count := 0
	for _, volume := range e.volumes(ns) {
		mark := ""
		if volume == mounted {
			mark = " (mounted)"
		}
		e.line("  %s%s", volume, mark)
		count++
	}
	if count == 0 {
		e.line("  (no volume)")
	}
}

// volumes lists the PVCs of namespace whose name ends with -mysql-0.
func (e *env) volumes(namespace string) []string {
	res, err := e.exec("kubectl", e.kubectlArgs(namespace, "get", "pvc", "-o", "jsonpath="+volumeJSONPath), nil)
	if err != nil || res.Code != 0 {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasSuffix(line, "-mysql-0") {
			out = append(out, line)
		}
	}
	return out
}

// claimMounted returns the claim prefix of the StatefulSet, empty if absent.
func (e *env) claimMounted(namespace string) string {
	res, err := e.exec("kubectl", e.kubectlArgs(namespace, "get", "statefulset", "mysql",
		"-o", "jsonpath="+claimJSONPath), nil)
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// claimChoose reuses the one existing volume, or refuses when several are
// present and the user has to choose one with "devzone mysql volume".
func (e *env) claimChoose(namespace string) (string, int) {
	list := e.volumes(namespace)
	if len(list) == 0 {
		return "donnees", 0
	}
	if len(list) == 1 {
		return strings.TrimSuffix(list[0], "-mysql-0"), 0
	}
	if e.opts.Err != nil {
		fmt.Fprintln(e.opts.Err, "devzone : catalog mysql : several volumes found:")
		for _, volume := range list {
			fmt.Fprintf(e.opts.Err, "  %s\n", volume)
		}
		fmt.Fprintln(e.opts.Err, "devzone : catalog mysql : choose one with devzone mysql volume <name>")
	}
	return "", 2
}
