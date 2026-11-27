package command

import "os"

// uninstallPlan lists the Kubernetes objects of this instance and the state
// files of the folder. It is read before anything is removed.
type uninstallPlan struct {
	kubeContext   string
	noCluster     bool
	namespaces    []string
	applications  []string
	tempAccounts  []string
	devzoneFiles  []string
	keptObjects   []string
	workspaceKept string
}

// empty reports whether no Kubernetes object is planned for removal. The state
// files are not counted: they are removed once the removal succeeded.
func (p uninstallPlan) empty() bool {
	return len(p.namespaces) == 0 && len(p.applications) == 0 && len(p.tempAccounts) == 0
}

// devzoneInstance returns the instance name of this folder: DEVZONE_VOLUMES, as
// the shell uninstaller read it, or "devzone" when it is not set. The pod gets
// the same name as DEVZONE_INSTANCE from devcontainer.json.
func devzoneInstance() string {
	if v := os.Getenv("DEVZONE_VOLUMES"); v != "" {
		return v
	}
	return "devzone"
}

// dockerCommand returns the Docker command the host calls: DEVZONE_DOCKER when
// a test or a user names another one, else "docker".
func dockerCommand() string {
	if v := os.Getenv("DEVZONE_DOCKER"); v != "" {
		return v
	}
	return "docker"
}

// uninstallCommandName is the command the user re-runs after a host problem:
// DEVZONE_COMMAND when the caller names it, else "devzone uninstall".
func uninstallCommandName() string {
	if v := os.Getenv("DEVZONE_COMMAND"); v != "" {
		return v
	}
	return "devzone uninstall"
}

// insideContainer reports whether the command runs inside the devzone pod. Then
// docker talks to the host Docker, so the host resources are not inventoried.
// DEVZONE_IN_CONTAINER=yes|no forces the answer (tests run in a container).
func insideContainer() bool {
	switch os.Getenv("DEVZONE_IN_CONTAINER") {
	case "yes":
		return true
	case "no":
		return false
	}
	info, err := os.Stat("/.dockerenv")
	return err == nil && !info.IsDir()
}

// uninstallRoot returns the devzone folder: DEVZONE_ROOT, else the working
// directory.
func uninstallRoot() (string, error) {
	if root := os.Getenv("DEVZONE_ROOT"); root != "" {
		return root, nil
	}
	return os.Getwd()
}
