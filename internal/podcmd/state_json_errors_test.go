package podcmd

import (
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestStateJSONFrozenErrors fixes the null values, error keys and exit code
// when the version, tools, identities, modules, ports and catalog fail.
func TestStateJSONFrozenErrors(t *testing.T) {
	root, _, stateFile := jsonFixture(t)
	writeJSONFile(t, stateFile, "gitlab=on\npostgres=on\nmysql=on\ncluster=remote.example\n")
	t.Setenv("DEVZONE_PACKAGES_MARKER", filepath.Join(root, "absent-packages"))

	r := stubRunner{t: t, responses: map[string]exec.Result{}}
	r.program(nil, 0, "Test User\n", "git", "config", "--get", "user.name")
	r.program(nil, 0, "test@example.invalid\n", "git", "config", "--get", "user.email")
	r.program(nil, 1, "not logged in\n", "gh", "auth", "status")
	r.program(nil, 1, "", "devzone", "gitlab", "status")
	r.program(nil, 1, "", "bash", filepath.Join(root, ".devcontainer", "postgres", "postgres.sh"), "status")
	r.program(nil, 1, "", "devzone", "mysql", "status")
	r.program(nil, 1, "", "bash", filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "--installees")
	r.program(nil, 0, "docker-desktop\n", "kubectl", "config", "view", "-o", `jsonpath={.contexts[?(@.name=="remote.example")].context.cluster}`)
	r.program(nil, 0, "https://remote.example:6443\n", "kubectl", "config", "view", "-o", `jsonpath={.clusters[?(@.name=="docker-desktop")].cluster.server}`)
	r.program(nil, 0, "docker-desktop\n", "kubectl", "config", "current-context")
	r.program(nil, 0, "", "devzone", "cluster", "clean", "--quiet")
	r.program(nil, 0, "not-json\n", "devzone", "port", "list", "--json")
	r.program(nil, 0, "{bad}\n", "bash", filepath.Join(root, ".devcontainer", "catalog.sh"), "json")
	r.program(nil, 0, "", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")

	code, got := renderJSON(t, r, stateFile)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	want := `{
  "schema": 3,
  "devzone": {
    "version": null,
    "available": "3.2.2"
  },
  "git_identity": {
    "ok": true,
    "name": "Test User",
    "email": "test@example.invalid",
    "command": null
  },
  "platform": {
    "name": "github",
    "url": null,
    "github": null
  },
  "argocd_repo": null,
  "tools": {
    "outdated": null,
    "command": null
  },
  "modules": [
    {
      "name": "ai",
      "active": false,
      "description": "AI assistants: Claude Code, opencode",
      "state": "optional",
      "failed": null,
      "command": "devzone enable ai",
      "held-by-argocd": false
    },
    {
      "name": "kubernetes",
      "active": false,
      "description": "connection to the host cluster and metrics-server at startup",
      "state": "optional",
      "failed": null,
      "command": "devzone enable kubernetes",
      "held-by-argocd": false
    },
    {
      "name": "gitlab",
      "active": true,
      "description": "test GitLab in the services cluster",
      "state": null,
      "failed": null,
      "command": null,
      "held-by-argocd": false
    },
    {
      "name": "postgres",
      "active": true,
      "description": "shared PostgreSQL, one database per project",
      "state": null,
      "failed": null,
      "command": null,
      "held-by-argocd": false
    },
    {
      "name": "argocd",
      "active": false,
      "description": "Argo CD, deployment interface of the services cluster",
      "state": "optional",
      "failed": null,
      "command": "devzone enable argocd",
      "held-by-argocd": false
    },
    {
      "name": "mysql",
      "active": true,
      "description": "shared MySQL, one database per project",
      "state": null,
      "failed": null,
      "command": null,
      "held-by-argocd": false
    }
  ],
  "clusters": {
    "services": "remote.example",
    "services_remote": true,
    "work": "docker-desktop",
    "internal_work": false,
    "command": null
  },
  "ports": null,
  "applications": [],
  "credentials": null,
  "alerts": [
    {
      "code": "cluster_distant",
      "message": "remote cluster: remote.example — services on a remote cluster",
      "command": null
    }
  ],
  "errors": {
    "devzone": "folder_version unavailable",
    "github": "gh auth status failed",
    "tools": "outdated_tools unavailable",
    "modules": "catalog.sh json unavailable",
    "ports": "ports output unreadable"
  }
}
`
	checkJSON(t, root, got, want)
}
