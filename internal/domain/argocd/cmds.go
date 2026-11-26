package argocd

import "fmt"

// initCmd handles "init [--repo ...|--none|--gitlab]".
func (m *module) initCmd(args []string) int {
	if code := m.gitopsInit(args); code != 0 {
		return code
	}
	if m.isInstalled() {
		return m.gitopsRoot()
	}
	return 0
}

// applyCmd handles "apply".
func (m *module) applyCmd() int {
	if !m.isInstalled() {
		fmt.Fprintln(m.errOut, "devzone : argocd : module off: devzone enable argocd")
		return 2
	}
	if code := m.gitopsInit(nil); code != 0 {
		return code
	}
	if code := m.gitopsRoot(); code != 0 {
		return code
	}
	return m.appsReconcile()
}

// appCmd handles "app add|list|remove".
func (m *module) appCmd(args []string) int {
	if len(args) == 0 {
		return appsUsage(m.errOut, "devzone argocd app")
	}
	switch args[0] {
	case "add":
		return m.appsAdd(args[1:])
	case "list":
		return m.appsList()
	case "remove":
		return m.appsRemove(args[1:])
	default:
		return appsUsage(m.errOut, "devzone argocd app")
	}
}
