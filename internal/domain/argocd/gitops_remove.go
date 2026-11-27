package argocd

import (
	"context"
	"io"
	"os"
)

// RemoveApplicationFile takes the Application name out of the GitOps repository,
// as the first half of gitops_delete_application does: its file apps/<name>.yaml
// is removed (through gh for GitHub, through the API for GitLab), then the root
// Application is refreshed so that it never recreates the child. Without a
// designated repository nothing runs. It returns 1 when the repository refuses
// the removal: the caller must then keep the Application in the cluster, since
// the file would still declare it. The cluster delete stays with the caller.
// Why: a workspace stop that deletes the Application while its file remains
// would see the root Application recreate it at the next sync.
func RemoveApplicationFile(ctx context.Context, opts Options, name string) int {
	if opts.Err == nil {
		opts.Err = os.Stderr
	}
	m, err := newModule(ctx, opts, io.Discard, opts.Err)
	if err != nil {
		_, _ = io.WriteString(opts.Err, err.Error()+"\n")
		return 1
	}
	if !m.gitopsEnabled() {
		return 0
	}
	if code := m.gitopsDelete("apps/"+name+".yaml", "devzone: application "+name+" removed"); code != 0 {
		return code
	}
	m.gitopsRefresh()
	return 0
}
