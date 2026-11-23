package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
)

// ticketEnv holds the roots of the ticket worktrees and whether the command runs in the Kubernetes pod.
type ticketEnv struct {
	projects   string
	tools      string
	kubernetes bool
}

// ticketRefusal is a refusal of the command: "devzone ticket: <message>" on the error output, status 2.
type ticketRefusal string

// Error returns the message of the refusal as the error text.
func (r ticketRefusal) Error() string { return string(r) }

// ticketEnvFromOS reads DEVZONE_TICKET_PROJECTS (default /workspaces/projets), DEVZONE_TICKET_TOOLS (default /workspaces/devzone) and DEVZONE_WORKSPACE=kubernetes.
func ticketEnvFromOS() ticketEnv {
	env := ticketEnv{projects: "/workspaces/projets", tools: "/workspaces/devzone"}
	if v := os.Getenv("DEVZONE_TICKET_PROJECTS"); v != "" {
		env.projects = v
	}
	if v := os.Getenv("DEVZONE_TICKET_TOOLS"); v != "" {
		env.tools = v
	}
	env.kubernetes = os.Getenv("DEVZONE_WORKSPACE") == "kubernetes"
	return env
}

// ticketPaths returns the clone and the worktree of ticket n of repo, or a ticketRefusal.
func ticketPaths(env ticketEnv, repo, n string) (clone, wt string, err error) {
	var prefix string
	switch repo {
	case "devzone":
		prefix = "dz"
	case "repowarden":
		prefix = "rw"
	default:
		return "", "", ticketRefusal(fmt.Sprintf("unknown repo: %s (devzone or repowarden)", repo))
	}
	if env.kubernetes {
		clone = filepath.Join(env.projects, repo)
		wt = filepath.Join(env.projects, repo+"-wt", prefix+"-"+n)
	} else {
		if repo != "devzone" {
			return "", "", ticketRefusal(fmt.Sprintf("repo %s only in the Kubernetes workspace pod", repo))
		}
		clone = env.tools
		wt = filepath.Join(env.tools, "workspace", "wt", prefix+"-"+n)
	}
	if _, statErr := os.Stat(filepath.Join(clone, ".git")); statErr != nil {
		return "", "", ticketRefusal(fmt.Sprintf("no clone in %s (from the workstation: devzone workspace clone <url>)", clone))
	}
	return clone, wt, nil
}
