package argocd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Run executes the pod argocd subcommand with the given arguments.
func Run(ctx context.Context, args []string, out, errOut io.Writer, opts Options) int {
	if ctx == nil {
		ctx = context.Background()
	}
	if out == nil {
		out = os.Stdout
	}
	if errOut == nil {
		errOut = os.Stderr
	}
	m, err := newModule(ctx, opts, out, errOut)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if len(args) == 0 {
		return usage(errOut)
	}
	switch args[0] {
	case "install":
		return m.install()
	case "uninstall":
		return m.uninstall()
	case "status":
		return m.status()
	case "relay-start":
		return m.relayStartCmd()
	case "relay-stop":
		return m.relayStopCmd()
	case "init":
		return m.initCmd(args[1:])
	case "apply":
		return m.applyCmd()
	case "services-hook":
		return m.servicesHook(args[1:])
	case "catalog-active":
		return m.catalogActiveCmd(args[1:])
	case "catalog-apply":
		return m.catalogApplyCmd(args[1:])
	case "catalog-application-exists":
		return m.catalogApplicationExistsCmd(args[1:])
	case "catalog-delete":
		return m.catalogDeleteCmd(args[1:])
	case "catalog-load":
		return 0
	case "revision":
		return m.catalogRevisionCmd(args[1:])
	case "chart-require":
		if len(args) != 2 {
			return 2
		}
		return m.chartRequire(args[1])
	case "gitops-apply":
		// gitops-apply <name> <kind> <ns> <repo> <revision> <path> [params...]
		if len(args) < 7 {
			return 2
		}
		return m.gitopsApplyApplication(args[1], args[2], args[3], args[4], args[5], args[6], args[7:]...)
	case "conf-get":
		if len(args) != 4 {
			return 2
		}
		fmt.Fprint(out, Conf{Path: args[1]}.Get(args[2], args[3]))
		return 0
	case "app":
		if os.Getenv("DEVZONE_WORKSPACE") == "kubernetes" {
			fmt.Fprintf(errOut, "devzone : argocd : in the workspace pod, on the workstation: devzone workspace argocd app %s\n", strings.Join(args[1:], " "))
			return 2
		}
		if !m.isInstalled() {
			fmt.Fprintln(errOut, "devzone : argocd : module off: devzone enable argocd")
			return 2
		}
		return m.appCmd(args[1:])
	default:
		return usage(errOut)
	}
}

// usage prints the argocd help line used by the shell command.
func usage(errOut io.Writer) int {
	fmt.Fprintln(errOut, "devzone argocd : install | uninstall | status | init [--repo <url>|--none] | apply | app add|list|remove")
	return 1
}

// newModule resolves paths and collaborators for argocd commands.
func newModule(ctx context.Context, opts Options, out, errOut io.Writer) (*module, error) {
	root := opts.Root
	if root == "" {
		root = os.Getenv("DEVZONE_ROOT")
	}
	if root == "" && opts.CodeRoot != "" {
		root = filepath.Dir(opts.CodeRoot)
	}
	if root == "" {
		return nil, fmt.Errorf("devzone : argocd : devzone root unavailable (DEVZONE_ROOT)")
	}
	codeRoot := opts.CodeRoot
	if codeRoot == "" {
		codeRoot = os.Getenv("DEVZONE_POD_SCRIPT")
		if codeRoot != "" {
			codeRoot = filepath.Dir(codeRoot)
		}
	}
	if codeRoot == "" {
		codeRoot = filepath.Join(root, ".devcontainer")
	}
	statePath := opts.StatePath
	if statePath == "" {
		statePath = os.Getenv("DEVZONE_STATE")
	}
	if statePath == "" {
		statePath = filepath.Join(root, ".devzone.modules")
	}
	host := opts.KubeHost
	if host == "" {
		host = os.Getenv("DEVZONE_KUBE_HOST")
	}
	if host == "" {
		host = filepath.Join(os.Getenv("HOME"), ".kube", "hote.config")
	}
	config := opts.KubeConfig
	if config == "" {
		config = os.Getenv("DEVZONE_KUBE_CONFIG")
	}
	if config == "" {
		config = filepath.Join(os.Getenv("HOME"), ".kube", "config")
	}
	runner := opts.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	version := os.Getenv("ARGOCD_VERSION")
	if version == "" {
		version = defaultVersion
	}
	port := os.Getenv("ARGOCD_PORT")
	if port == "" {
		port = defaultPort
	}
	wait := os.Getenv("ARGOCD_ATTENTE")
	if wait == "" {
		wait = defaultWait
	}
	return &module{
		ctx: ctx, runner: runner, out: out, errOut: errOut,
		root: root, codeRoot: codeRoot, state: statePath, host: host, config: config,
		secrets: filepath.Join(root, "workspace", ".argocd"),
		ns:      defaultNS, version: version, port: port, wait: wait,
	}, nil
}
