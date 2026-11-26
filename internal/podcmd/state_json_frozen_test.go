package podcmd

import (
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestStateJSONFrozenFull fixes the order and values of a complete status:
// versions, platform, GitHub, tools, modules, clusters, ports, alerts, errors.
func TestStateJSONFrozenFull(t *testing.T) {
	root, code, stateFile := jsonFixture(t)
	writeJSONFile(t, stateFile, "ai=on\nkubernetes=on\ngitlab=on\npostgres=on\nargocd=on\nmysql=on\n"+
		"platform=gitlab\ngitlab_url=https://gitlab.example/base\ncluster=remote.example\nports=8080,3000\n")
	writeJSONFile(t, filepath.Join(root, ".devzone.version"), "version 3.2.1\n")
	writeJSONFile(t, filepath.Join(root, ".argocd.conf"), "[argocd]\n repo = https://github.com/tester/devzone-argocd.git # note\n")
	writeJSONFile(t, filepath.Join(root, ".password"), "never printed\n")
	writeJSONFile(t, filepath.Join(root, "packages.failed"), "npm\nhelm\n")

	r := stubRunner{t: t, responses: map[string]exec.Result{}}
	r.program(nil, 0, "Test User\n", "git", "config", "--get", "user.name")
	r.program(nil, 0, "test@example.invalid\n", "git", "config", "--get", "user.email")
	r.program(nil, 0, "Token scopes: 'gist', 'repo'\n", "gh", "auth", "status")
	versions := filepath.Join(root, "manage", "scripts", "ci", "versions.sh")
	r.program(nil, 0, "repowarden 9.9.9 9.9.8\nopencode-ai 1.19.6 1.19.5\n", "bash", versions, "--installees")
	r.program(nil, 0, "gitlab ready\n", "devzone", "gitlab", "status")
	r.program(nil, 0, "postgres ready\n", "bash", filepath.Join(code, "postgres", "postgres.sh"), "status")
	r.program(nil, 0, "argocd ready\n", filepath.Join(code, "devzone"), "argocd", "status")
	r.program(nil, 0, "mysql ready\n", "devzone", "mysql", "status")
	r.program(nil, 0, "docker-desktop\n", "kubectl", "config", "view", "-o", `jsonpath={.contexts[?(@.name=="remote.example")].context.cluster}`)
	r.program(nil, 0, "https://remote.example:6443\n", "kubectl", "config", "view", "-o", `jsonpath={.clusters[?(@.name=="docker-desktop")].cluster.server}`)
	r.program(nil, 0, "kind-devzone\n", "kubectl", "config", "current-context")
	r.program([]string{"KUBECONFIG=" + filepath.Join(root, "host.config")}, 0, "docker-desktop\n", "kubectl", "config", "current-context")
	r.program(nil, 0, "", "kubectl", "--context", "docker-desktop", "--request-timeout=3s", "get", "--raw", "/readyz")
	r.program(nil, 3, "", "devzone", "cluster", "clean", "--quiet")
	r.program(nil, 0, `[{"port":8080,"active":true,"application":"application responds","auto":false}]`, "devzone", "port", "list", "--json")
	r.program(nil, 0, `[{"name":"demo","available":true}]`, "bash", filepath.Join(code, "catalog.sh"), "json")
	r.program(nil, 0, "worktree <ROOT>/gone\ncommit abc\n", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")

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
    "ok": true,
    "name": "Test User",
    "email": "test@example.invalid",
    "command": null
  },
  "platform": {
    "name": "gitlab",
    "url": "https://gitlab.example/base",
    "github": null
  },
  "argocd_repo": "https://github.com/tester/devzone-argocd.git",
  "tools": {
    "outdated": [
      {
        "package": "repowarden",
        "frozen": "9.9.9",
        "installed": "9.9.8"
      },
      {
        "package": "opencode-ai",
        "frozen": "1.19.6",
        "installed": "1.19.5"
      }
    ],
    "command": "devzone apply"
  },
  "modules": [
    {
      "name": "ai",
      "active": true,
      "description": "AI assistants: Claude Code, opencode",
      "state": "active",
      "failed": null,
      "command": null
    },
    {
      "name": "kubernetes",
      "active": true,
      "description": "connection to the host cluster and metrics-server at startup",
      "state": "active",
      "failed": null,
      "command": null
    },
    {
      "name": "gitlab",
      "active": true,
      "description": "test GitLab in the services cluster",
      "state": "gitlab ready",
      "failed": null,
      "command": null
    },
    {
      "name": "postgres",
      "active": true,
      "description": "shared PostgreSQL, one database per project",
      "state": "postgres ready",
      "failed": null,
      "command": null
    },
    {
      "name": "argocd",
      "active": true,
      "description": "Argo CD, deployment interface of the services cluster",
      "state": "argocd ready",
      "failed": null,
      "command": null
    },
    {
      "name": "mysql",
      "active": true,
      "description": "shared MySQL, one database per project",
      "state": "mysql ready",
      "failed": null,
      "command": null
    }
  ],
  "clusters": {
    "services": "remote.example",
    "services_remote": true,
    "work": "kind-devzone",
    "internal_work": true,
    "command": "devzone use docker-desktop"
  },
  "ports": [
    {
      "port": 8080,
      "active": true,
      "application": "application responds",
      "auto": false
    }
  ],
  "applications": [
    {
      "name": "demo",
      "available": true
    }
  ],
  "credentials": "<ROOT>/.password",
  "alerts": [
    {
      "code": "cluster_disk",
      "message": "cluster disk almost full",
      "command": "devzone repair"
    },
    {
      "code": "packages",
      "message": "npm, helm",
      "command": "devzone packages"
    },
    {
      "code": "worktree",
      "message": "<ROOT>/gone missing here (created outside the container?)",
      "command": null
    },
    {
      "code": "cluster_distant",
      "message": "remote cluster: remote.example — services on a remote cluster",
      "command": null
    },
    {
      "code": "cluster_interne",
      "message": "work cluster: kind-devzone (devzone internal cluster)",
      "command": "devzone use docker-desktop"
    }
  ],
  "errors": {}
}
`
	checkJSON(t, root, got, want)
}
