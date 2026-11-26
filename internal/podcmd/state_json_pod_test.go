package podcmd

import (
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestStateJSONFrozenPod fixes the in-cluster module states: DNS presence
// replaces the workstation installers, with the instance suffix in the name.
func TestStateJSONFrozenPod(t *testing.T) {
	root, code, stateFile := jsonFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	t.Setenv("DEVZONE_INSTANCE", "test")
	t.Setenv("DEVZONE_PACKAGES_MARKER", filepath.Join(root, "absent-packages"))
	writeJSONFile(t, stateFile, "gitlab=on\npostgres=off\nargocd=on\n")
	writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 3.2.1\n")

	r := stubRunner{t: t, responses: map[string]exec.Result{}}
	r.program(nil, 1, "", "git", "config", "--get", "user.name")
	r.program(nil, 1, "", "git", "config", "--get", "user.email")
	r.program(nil, 0, "Token scopes: 'workflow'\n", "gh", "auth", "status")
	r.program(nil, 0, "", "bash", filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "--installees")
	r.program(nil, 0, "", "getent", "hosts", "gitlab-webservice-default.devzone-gitlab-test.svc")
	r.program(nil, 1, "", "getent", "hosts", "postgres.devzone-postgres.svc")
	r.program(nil, 1, "", "getent", "hosts", "argocd-server.devzone-argocd.svc")
	r.program(nil, 0, "docker-desktop\n", "kubectl", "config", "current-context")
	r.program(nil, 0, "", "devzone", "cluster", "clean", "--quiet")
	r.program(nil, 0, "[]\n", "devzone", "port", "list", "--json")
	r.program(nil, 0, "[]\n", "bash", filepath.Join(code, "catalog.sh"), "json")
	r.program(nil, 0, "", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")

	codeExit, got := renderJSON(t, r, stateFile)
	if codeExit != 0 {
		t.Fatalf("exit %d", codeExit)
	}
	want := `{
  "schema": 3,
  "devzone": {
    "version": "3.2.1",
    "available": "3.2.2"
  },
  "git_identity": {
    "ok": false,
    "name": null,
    "email": null,
    "command": "gh auth login -s workflow (automatic), or git config --file ~/.config/git/config user.name \"<name>\" and user.email \"<email>\""
  },
  "platform": {
    "name": "github",
    "url": null,
    "github": {
      "connected": true,
      "workflow": true,
      "command": null
    }
  },
  "argocd_repo": null,
  "tools": {
    "outdated": [],
    "command": null
  },
  "modules": [
    {
      "name": "ai",
      "active": false,
      "description": "AI assistants: Claude Code, opencode",
      "state": "optional",
      "failed": null,
      "command": "devzone enable ai"
    },
    {
      "name": "kubernetes",
      "active": false,
      "description": "connection to the host cluster and metrics-server at startup",
      "state": "optional",
      "failed": null,
      "command": "devzone enable kubernetes"
    },
    {
      "name": "gitlab",
      "active": true,
      "description": "test GitLab in the services cluster",
      "state": "active: gitlab-webservice-default.devzone-gitlab-test.svc",
      "failed": null,
      "command": null
    },
    {
      "name": "postgres",
      "active": false,
      "description": "shared PostgreSQL, one database per project",
      "state": "optional",
      "failed": null,
      "command": "devzone workspace services enable postgres"
    },
    {
      "name": "argocd",
      "active": true,
      "description": "Argo CD, deployment interface of the services cluster",
      "state": "not in the cluster",
      "failed": null,
      "command": "devzone workspace services enable argocd"
    },
    {
      "name": "mysql",
      "active": false,
      "description": "shared MySQL, one database per project",
      "state": "optional",
      "failed": null,
      "command": "devzone enable mysql"
    }
  ],
  "clusters": {
    "services": null,
    "services_remote": false,
    "work": "docker-desktop",
    "internal_work": false,
    "command": null
  },
  "ports": [],
  "applications": [],
  "credentials": null,
  "alerts": [],
  "errors": {}
}
`
	checkJSON(t, root, got, want)
}
