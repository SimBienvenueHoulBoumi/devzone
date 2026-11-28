package podcmd

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"os"
	"path/filepath"
)

// moduleNames are the modules of devzone status, in the shell order.
var moduleNames = []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}

// moduleDescription returns the short purpose of a module, as the shell does.
func moduleDescription(name string) string {
	switch name {
	case "ai":
		return "AI assistants: Claude Code, opencode"
	case "kubernetes":
		return "connection to the host cluster and metrics-server at startup"
	case "gitlab":
		return "test GitLab in the services cluster"
	case "postgres":
		return "shared PostgreSQL, one database per project"
	case "argocd":
		return "Argo CD, deployment interface of the services cluster"
	case "mysql":
		return "shared MySQL, one database per project"
	}
	return ""
}

// serviceModule reports whether a module is installed in the services cluster.
func serviceModule(name string) bool {
	return name == "gitlab" || name == "postgres" || name == "argocd"
}

// heldByArgoCD reports whether a service is driven by an Argo CD Application:
// both the module and Argo CD must be on. Why: status must say which services
// a change of the GitOps repository will update, without contacting a cluster.
func heldByArgoCD(d jsonDeps, name string) bool {
	if name != "gitlab" && name != "postgres" && name != "mysql" {
		return false
	}
	return d.st.Get(name) == "on" && d.st.Get("argocd") == "on"
}

// serviceDNS returns the in-cluster DNS name of a service module.
func serviceDNS(name string) string {
	suffix := ""
	if instance := os.Getenv("DEVZONE_INSTANCE"); instance != "" && instance != "devzone" {
		suffix = "-" + instance
	}
	switch name {
	case "gitlab":
		return "gitlab-webservice-default." + config.NamespaceGitLab + suffix + ".svc"
	case "postgres":
		return "postgres." + config.NamespacePostgres + ".svc"
	case "argocd":
		return "argocd-server." + config.NamespaceArgoCD + ".svc"
	}
	return ""
}

// modulesJSON reports the state and command of each module, in the shell order.
func modulesJSON(d jsonDeps, errs jsonObject) ([]any, jsonObject) {
	out := make([]any, 0, len(moduleNames))
	inPod := os.Getenv("DEVZONE_WORKSPACE") == "kubernetes"
	for _, name := range moduleNames {
		active := d.st.Get(name) == "on"
		var stateValue any = "optional"
		var failed any
		var command any = "devzone enable " + name
		switch {
		case inPod && serviceModule(name):
			dns := serviceDNS(name)
			_, code, err := d.run("getent", "hosts", dns)
			if err == nil && code == 0 {
				stateValue = "active: " + dns
				command = nil
			} else if active {
				stateValue = "not in the cluster"
				command = "devzone workspace services enable " + name
			} else {
				command = "devzone workspace services enable " + name
			}
		case active:
			stateValue, failed, command, errs = activeModuleJSON(d, name, errs)
		}
		out = append(out, jsonObject{
			{key: "name", value: name},
			{key: "active", value: active},
			{key: "description", value: moduleDescription(name)},
			{key: "state", value: stateValue},
			{key: "failed", value: failed},
			{key: "command", value: command},
			{key: "held-by-argocd", value: heldByArgoCD(d, name)},
		})
	}
	return out, errs
}

// activeModuleJSON resolves the detailed state of an active module.
func activeModuleJSON(d jsonDeps, name string, errs jsonObject) (any, any, any, jsonObject) {
	marker := d.st.Path() + "-failed-" + name
	if data, err := os.ReadFile(marker); err == nil {
		return "failed", trimNewlines(string(data)), "devzone apply", errs
	}
	var out string
	var code int
	var err error
	switch name {
	case "gitlab":
		out, code, err = d.run("devzone", "gitlab", "status")
		if err != nil || code != 0 {
			errs.set("modules", "gitlab status unavailable")
			return nil, nil, nil, errs
		}
	case "postgres":
		script := filepath.Join(d.code, name, name+".sh")
		out, code, err = d.run("bash", script, "status")
		if err != nil || code != 0 {
			errs.set("modules", name+".sh state unavailable")
			return nil, nil, nil, errs
		}
	case "argocd":
		out, code, err = d.run(filepath.Join(d.code, "devzone"), "argocd", "status")
		if err != nil || code != 0 {
			return nil, nil, nil, errs
		}
	case "mysql":
		out, code, err = d.run("devzone", "mysql", "status")
		if err != nil || code != 0 {
			errs.set("modules", "mysql.sh status unavailable")
			return nil, nil, nil, errs
		}
	default:
		return "active", nil, nil, errs
	}
	value := trimNewlines(out)
	if value == "" {
		return nil, nil, nil, errs
	}
	return value, nil, nil, errs
}
