package command

// helpTemplate is the help text of manage/devzone (show_help), copied line by
// line from the bash heredoc: the French and English lines are kept as they are.
// {version} stands for the version of the package.
const helpTemplate = `devzone {version} : environnement de développement conteneurisé

  devzone <dossier> [--gitops github|none|<url>] [--kubernetes|--docker]
                           crée un devzone dans <dossier> puis le lance ;
                           GitOps repository for Argo CD: github, or a URL, or none
                           --kubernetes: workspace in the cluster (default when it answers;
                           fails with nothing created without one)
                           --docker: deprecated Docker workstation, no cluster check
                           (without a cluster nothing is created, no silent Docker)
  devzone update [--yes] [--sans-reconstruire]
                           dans un dossier devzone : passe à la version du paquet
                           (sauvegarde les fichiers remplacés, propose make rebuild)
  devzone uninstall        dans un dossier devzone : retire conteneur, image, volumes
                           (à lancer avant npm uninstall -g devzone)
  devzone workspace start|stop|status|shell|update
  devzone workspace vscode|copy-to|copy-from|clone|migrate|revert|clean-docker
                           poste Kubernetes : pilote le chart devzone-workspace
  devzone workspace services enable|disable <service>|status
                           services (gitlab, postgres, argocd) du workspace Kubernetes
  devzone workspace argocd status|init|apply|app add|list|remove
                           Argo CD du workspace : dépôt GitOps, .argocd.conf, projets
  (old French names: refused with the new name, see the README, « Removed names »)
  devzone --version
`
