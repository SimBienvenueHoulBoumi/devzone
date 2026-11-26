package command

// helpTemplate is the help text of manage/devzone (show_help), copied line by
// line from the bash heredoc: both copies are identical (parity tested).
// {version} stands for the version of the package.
const helpTemplate = `devzone {version}: development workspace in a Kubernetes cluster

  devzone <folder> [--gitops github|none|<url>] [--kubernetes]
                           creates a devzone in <folder> (package files, .argocd.conf,
                           .devzone.modules), then starts its workspace in the cluster;
                           a folder that is not empty is refused
                           GitOps repository for Argo CD: github, or a URL, or none
                           --kubernetes: workspace in the cluster (default when it answers;
                           fails with nothing created without one)
  devzone update [--yes]
                           in a devzone folder: replaces the package files with those of
                           the installed package, after backing up the replaced files in
                           .devzone.backup/ (the new image is used at the next workspace start)
  devzone uninstall [--yes]
                           in a devzone folder: removes Kubernetes objects of this devzone
                           instance (namespaces, Argo CD Applications, temporary accounts,
                           .devzone.* files); workspace/ is kept; asks for confirmation
  devzone ai [check|rapport|guard]         host models, update report or tool-call guard
  devzone workspace start|stop|status|shell|update|deploy
  devzone workspace vscode|copy-to|copy-from|clone
                           Kubernetes workspace: drives the devzone-workspace chart
                           (start installs it, stop removes it from the cluster)
  devzone workspace services enable|disable <service>|status
                           services (gitlab, postgres, argocd) of the Kubernetes workspace
  devzone workspace ports enable|disable
                           automatic start of the port watcher on the workstation
  devzone workspace argocd status|init|apply|app add|list|remove
                           Argo CD of the workspace: GitOps repository, .argocd.conf, projects
  devzone --version
`
