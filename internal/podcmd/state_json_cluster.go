package podcmd

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// servicesClusterJSON returns the chosen services cluster and its remote flag.
func servicesClusterJSON(d jsonDeps) (any, bool) {
	services := d.st.Get("cluster")
	if services == "" {
		return nil, false
	}
	return services, !clusterIsLocal(d, services)
}

// clusterIsLocal reports whether a context targets a local cluster, from its
// kubeconfig only, like cluster.sh.
func clusterIsLocal(d jsonDeps, ctx string) bool {
	if strings.HasPrefix(ctx, "kind-") {
		return true
	}
	cluster, code, err := d.run("kubectl", "config", "view", "-o", `jsonpath={.contexts[?(@.name=="`+ctx+`")].context.cluster}`)
	if err != nil || code != 0 || cluster == "" {
		return false
	}
	cluster = trimNewlines(cluster)
	server, code, err := d.run("kubectl", "config", "view", "-o", `jsonpath={.clusters[?(@.name=="`+cluster+`")].cluster.server}`)
	if err != nil || code != 0 || server == "" {
		return false
	}
	server = trimNewlines(server)
	switch {
	case strings.HasPrefix(ctx, "kind-"), ctx == "docker-desktop", ctx == "rancher-desktop", ctx == "orbstack", ctx == "minikube":
		return true
	}
	host := server
	if i := strings.Index(host, "://"); i >= 0 {
		host = host[i+3:]
	}
	if i := strings.IndexByte(host, '/'); i >= 0 {
		host = host[:i]
	}
	if strings.HasPrefix(host, "[") {
		if i := strings.IndexByte(host, ']'); i >= 0 {
			host = host[1:i]
		}
	} else if i := strings.IndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	switch host {
	case "127.0.0.1", "localhost", "::1", "host.docker.internal":
		return true
	}
	return strings.HasSuffix(host, "-control-plane")
}

// workClusterJSON returns the working context, whether it is an internal one,
// and the host context to suggest when leaving it.
func workClusterJSON(d jsonDeps) (any, bool, string) {
	out, _, _ := d.run("kubectl", "config", "current-context")
	work := trimNewlines(out)
	if !strings.HasPrefix(work, "kind-gitlab") && !strings.HasPrefix(work, "kind-devzone") {
		return strOrNil(work), false, ""
	}
	host := filepath.Join(os.Getenv("HOME"), ".kube", "hote.config")
	if v := os.Getenv("DEVZONE_KUBE_HOST"); v != "" {
		host = v
	}
	out, _, _ = d.runEnv([]string{"KUBECONFIG=" + host}, "kubectl", "config", "current-context")
	hostCtx := trimNewlines(out)
	if hostCtx == "" {
		return strOrNil(work), false, ""
	}
	_, code, err := d.run("kubectl", "--context", hostCtx, "--request-timeout=3s", "get", "--raw", "/readyz")
	return strOrNil(work), err == nil && code == 0, hostCtx
}

// clustersJSON reports the services and working clusters, in the shell order.
func clustersJSON(services any, servicesRemote bool, work any, workInternal bool, hostCtx string) jsonObject {
	var command any
	if workInternal {
		command = "devzone use " + hostCtx
	}
	return jsonObject{
		{key: "services", value: services},
		{key: "services_remote", value: servicesRemote},
		{key: "work", value: work},
		{key: "internal_work", value: workInternal},
		{key: "command", value: command},
	}
}

// appendClusterDiskAlert reports a nearly full disk when the cluster cleanup
// exits with the dedicated code 3.
func appendClusterDiskAlert(d jsonDeps, alerts []any) []any {
	_, code, _ := d.run("devzone", "cluster", "clean", "--quiet")
	if code == 3 {
		return appendAlert(alerts, "cluster_disk", "cluster disk almost full", "devzone repair")
	}
	return alerts
}

// appendOtherAlerts adds the package, worktree and cluster alerts in the shell order.
func appendOtherAlerts(d jsonDeps, alerts []any, services any, servicesRemote bool, work any, workInternal bool, hostCtx string) []any {
	marker := os.Getenv("DEVZONE_PACKAGES_MARKER")
	if marker == "" {
		marker = "/tmp/devzone-packages.failed"
	}
	if data, err := os.ReadFile(marker); err == nil {
		var names []string
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" {
				names = append(names, line)
			}
		}
		if len(names) > 0 {
			alerts = appendAlert(alerts, "packages", strings.Join(names, ", "), "devzone packages")
		}
	}
	for _, repo := range worktreeRepos(d.root) {
		out, _, _ := d.run("git", "-C", repo, "worktree", "list", "--porcelain")
		for _, line := range strings.Split(out, "\n") {
			if !strings.HasPrefix(line, "worktree ") {
				continue
			}
			path := strings.TrimPrefix(line, "worktree ")
			if _, err := os.Stat(path); os.IsNotExist(err) {
				alerts = appendAlert(alerts, "worktree", path+" missing here (created outside the container?)", "")
			}
		}
	}
	if servicesRemote {
		alerts = appendAlert(alerts, "cluster_distant", "remote cluster: "+services.(string)+" — services on a remote cluster", "")
	}
	if workInternal {
		workCtx, _ := work.(string)
		alerts = appendAlert(alerts, "cluster_interne", "work cluster: "+workCtx+" (devzone internal cluster)", "devzone use "+hostCtx)
	}
	return alerts
}

// worktreeRepos lists the repositories whose worktrees are checked, like missing_worktrees.
func worktreeRepos(root string) []string {
	var repos []string
	if _, err := os.Stat(filepath.Join(root, ".git")); err == nil {
		repos = append(repos, root)
	}
	workspace := filepath.Join(root, "workspace")
	var found []string
	_ = filepath.WalkDir(workspace, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		depth := strings.Count(strings.TrimPrefix(path, workspace), string(filepath.Separator))
		if depth > 3 {
			return fs.SkipDir
		}
		if entry.IsDir() && entry.Name() == ".git" && depth >= 2 {
			found = append(found, filepath.Dir(path))
		}
		return nil
	})
	return append(repos, found...)
}
