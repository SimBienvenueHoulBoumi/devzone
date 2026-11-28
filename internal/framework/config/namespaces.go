package config

// The namespace names are fixed installation defaults, shared by the code, the
// charts and the Applications. They are not configurable: renaming one only in
// the code would break that agreement, so the name has one definition here.
const (
	// NamespaceArgoCD is the namespace of Argo CD and of the Applications.
	NamespaceArgoCD = "devzone-argocd"
	// NamespaceGitLab is the namespace of the GitLab instance.
	NamespaceGitLab = "devzone-gitlab"
	// NamespaceWorkspace is the namespace of the workspace pod.
	NamespaceWorkspace = "devzone-workspace"
	// NamespacePostgres is the namespace of the PostgreSQL service.
	NamespacePostgres = "devzone-postgres"
)
