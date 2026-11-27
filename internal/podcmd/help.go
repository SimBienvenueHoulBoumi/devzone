package podcmd

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// podHelpText is the command list of the pod CLI, kept identical to the help of
// the removed shell library so existing documentation and scripts still match.
const podHelpText = `  Optional modules of devzone, enabled on demand, without rebuild:
  devzone                                  state of the modules
  devzone --version                        version of the workspace image (DEVZONE_VERSION)
  devzone platform                         GitHub (default) or GitLab
  devzone platform github                  back to GitHub: glab and config removed
  devzone platform gitlab                  GitLab, [--url URL] (default: gitlab module)
  devzone enable <module>                  enable and apply at once
  devzone disable <module> [--yes]         disable and apply at once (--yes: also deletes the data)
  devzone apply                            install what is enabled
  devzone repair                           repair gitlab, postgres, ports, passwords
  devzone catalog [list|apply|sync|resume|json|remove <app>]  applications of the catalog
  devzone metrics [context…] | remove [context…]  install or remove metrics-server (kubectl top, k9s)
  devzone use CTX [--confirm CTX]          switch the kubectl working cluster
  devzone clusters                         view of the connected clusters (work and services)
  devzone kube saved|choose|save|local|reachable|prompt  cluster helpers, in Go
  devzone is-enabled <module>              code 0 if enabled
  devzone test-bash32                      run the bats tests under bash 3.2 (legacy image)
  devzone test-gitlab                      end-to-end test of the GitLab module and platform
  devzone agent <folder> <instructions>    drive opencode with the instructions file
  devzone ai                               list the host (Ollama) models detected and the default model
  devzone ai check|rapport                 update state of each model | sizes, choices and reasons
  devzone ai guard [--format claude]       check one tool call on standard input (agent guard)
  devzone ticket <n> [--repo devzone|repowarden]  ticket worktree (ticket done <n> removes it)
  devzone build <folder> [--tag <name>]    build an image in the Kubernetes workspace (BuildKit)
  devzone enable postgres [--context CTX] [--confirm CTX]  shared PostgreSQL, cluster of choice
  devzone postgres create <project>        database and user of a project (also: list, psql, delete)
  devzone mysql create <project>           database and user of a MySQL project (also: list, delete)
  devzone enable llm [--preset light]      local code model (llama.cpp), devzone llm status
  devzone llm status | delete-data [--yes]  model and reachability | namespace and model removed
  devzone gitlab migrate [--yes]           GitLab in the services cluster, then the old kind cluster deleted
  devzone gitlab new-password [root|dev]   random password (root or dev) regenerated
  devzone enable argocd                    Argo CD in the services cluster, access https://127.0.0.1:8443
  devzone argocd status|relay-start|relay-stop  Argo CD (argocd module)
  devzone argocd app add <repo url> [path]|list|remove <N>  projects deployed by Argo CD (#516)
  devzone cluster [CTX] [--yes] [--confirm CTX]  services cluster of devzone, or change it
  devzone port [--close <n>]              list or remove a relay of the workstation
  devzone passwords                        regenerate .password and print its path
  devzone packages [add|remove|apply] …    system packages kept after a rebuild
`

// printHelp writes the pod command list to the CLI output, ignoring extra
// arguments, because the removed shell function did the same.
func printHelp(ctx *cli.Context) int {
	_, _ = io.WriteString(ctx.Out, podHelpText)
	return 0
}
