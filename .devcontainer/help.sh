#!/usr/bin/env bash
# Help of devzone (devzone --help, #557), sourced by devzone : English command
# names first ; the French names are still accepted and warn (deprecated).
# devzone_aide prints the list, indented like the other usage texts.
devzone_aide() {
    cat <<'AIDE'
  Optional modules of devzone, enabled on demand, without rebuild:
  devzone                                  state of the modules
  devzone platform                         GitHub (default) or GitLab
  devzone platform github                  back to GitHub: glab and config removed
  devzone platform gitlab                  GitLab, [--url URL] (default: gitlab module)
  devzone enable <module>                  enable and apply at once
  devzone disable <module> [--yes]         disable and apply at once (--yes: also deletes the data)
  devzone apply                            install what is enabled (post-create.sh)
  devzone repair                           repair Docker relay, gitlab, postgres, ports, passwords
  devzone start                            full start (startup scripts and summary)
  devzone metrics [context…]               install metrics-server (kubectl top, k9s)
  devzone use CTX [--confirm CTX]          switch the kubectl working cluster
  devzone clusters                         view of the connected clusters (work and services)
  devzone is-enabled <module>              code 0 if enabled (startup scripts)
  devzone test-bash32                      run the bats tests under bash 3.2 (Docker container)
  devzone test-gitlab                      end-to-end test of the GitLab module and platform
  devzone agent <folder> <instructions>    drive opencode with the instructions file
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
  devzone port [<n>|--close <n>]           relay of a container port to the workstation
  devzone passwords                        regenerate .password and print its path
  devzone packages [add|remove|apply] …    system packages kept after a rebuild
  Old French names are still accepted (deprecated).
AIDE
}
