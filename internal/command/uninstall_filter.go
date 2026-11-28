package command

import (
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// the list also holds the unsuffixed names of namespaces and Applications.
var devzoneObjectBases = []string{
	config.NamespaceWorkspace, config.NamespaceArgoCD, config.NamespacePostgres, "devzone-mysql",
	config.NamespaceGitLab, "devzone-llm", "devzone-system", "devzone",
}

// matchBase returns the known base of name when name is exactly a base, or a
// base followed by "-" and a suffix. The bare "devzone" only matches exactly:
// every devzone name starts with "devzone-", which would make every unknown
// name look like an instance suffix of it.
func matchBase(name string) (base string, exact bool) {
	for _, b := range devzoneObjectBases {
		if name == b {
			return b, true
		}
	}
	for _, b := range devzoneObjectBases {
		if b == "devzone" {
			continue
		}
		if strings.HasPrefix(name, b+"-") {
			return b, false
		}
	}
	return "", false
}

// belongsToInstance reports whether a labeled object name belongs to the
// instance. ours is true when a rule positively claims the name, doubt when no
// rule decides: the caller keeps a doubtful object and reports it. A name
// carrying another instance suffix belongs to neither and is dropped silently.
func belongsToInstance(name, instance string) (ours, doubt bool) {
	named := instance != "" && instance != "devzone"
	// App namespaces (devzone-app-*) and Applications (app-*) are never
	// suffixed: only the default instance claims them for sure.
	if strings.HasPrefix(name, "devzone-app-") || strings.HasPrefix(name, "app-") {
		return !named, named
	}
	base, exact := matchBase(name)
	if exact {
		// An unsuffixed devzone name: the default instance owns it, another
		// instance can only guess on a shared cluster (doubt).
		return !named, named
	}
	if base != "" {
		// name = base + "-" + suffix: an instance-suffixed object.
		if named && strings.TrimPrefix(name, base+"-") == instance {
			return true, false
		}
		return false, false // another instance's object
	}
	if strings.HasPrefix(name, "devzone-") {
		// A devzone name no base knows: in doubt, keep and report.
		// Previously the default instance would claim it, but that could delete
		// objects belonging to other instances. See INSTANCE_SUFFIX convention
		// in the former shell uninstaller and in .devcontainer/ files.
		return false, true
	}
	// Labeled but not a devzone name: doubt, keep and report.
	return false, true
}

// filterInstanceNamespaces splits labeled namespaces into the ones of this
// instance and the doubtful ones, which are kept and reported.
func filterInstanceNamespaces(names []string, instance string) (owned, doubtful []string) {
	for _, n := range names {
		ours, doubt := belongsToInstance(n, instance)
		switch {
		case ours:
			owned = append(owned, n)
		case doubt:
			doubtful = append(doubtful, "namespace/"+n)
		}
	}
	return owned, doubtful
}

// filterInstanceApps splits labeled Argo CD Applications, by their name, into
// the ones of this instance and the doubtful ones, which are kept and reported.
func filterInstanceApps(apps []string, instance string) (owned, doubtful []string) {
	for _, a := range apps {
		parts := strings.SplitN(a, "/", 2)
		if len(parts) != 2 {
			continue
		}
		ours, doubt := belongsToInstance(parts[1], instance)
		switch {
		case ours:
			owned = append(owned, a)
		case doubt:
			doubtful = append(doubtful, "application/"+parts[1])
		}
	}
	return owned, doubtful
}

// filterTempAccounts keeps the temporary service accounts created for devzone
// operations, but only those living in a namespace attributed to this instance.
// Accounts found in other namespaces are kept (and reported) for a named
// instance, and dropped silently when they belong to another instance.
func filterTempAccounts(accounts []string, instance string) (owned, doubtful []string) {
	for _, a := range accounts {
		parts := strings.SplitN(a, "/", 2)
		if len(parts) != 2 {
			continue
		}
		if parts[1] != "devzone-services-admin" {
			continue
		}
		ours, doubt := belongsToInstance(parts[0], instance)
		switch {
		case ours:
			owned = append(owned, a)
		case doubt:
			doubtful = append(doubtful, "serviceaccount/"+a)
		}
	}
	return owned, doubtful
}
