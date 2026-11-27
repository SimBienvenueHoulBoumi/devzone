package podcmd

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// changeModule runs enable (verb "on") or disable (verb "off") of a module
// with its extra arguments (change_module).
func (m *modules) changeModule(verb, module string, extra []string) int {
	errOut := m.ctx.Err
	if module == "" {
		fmt.Fprintf(errOut, "devzone : unknown module : (none) ; modules : %s\n", strings.Join(moduleNames, " "))
		return 1
	}
	// llm removed (#669): migration message, never unknown module.
	if module == "llm" {
		_ = m.init()
		m.removeLLMLine()
		fmt.Fprintln(m.ctx.Out, llmRemovedMessage)
		return 1
	}
	m.migrateLLM()
	if !isModule(module) {
		// An application of the catalog: the line is written, then applied
		if fileExists(filepath.Join(m.code, "catalog", module, "app.conf")) {
			m.writeValue(module, verb)
			return m.call(m.ctx.Out, "catalog", "apply")
		}
		fmt.Fprintf(errOut, "devzone : unknown module : %s ; modules : %s\n", module, strings.Join(moduleNames, " "))
		return 1
	}
	// In the Kubernetes workspace pod the services are installed from the
	// workstation (#528): the pod has no administrator access to the cluster.
	if m.inPod && serviceModule(module) && !m.servicesAdmin {
		if verb == "on" {
			fmt.Fprintf(errOut, "devzone: in the workspace pod, %s is installed from the workstation: devzone workspace services enable %s\n", module, module)
		} else {
			fmt.Fprintf(errOut, "devzone: in the workspace pod, %s is removed from the workstation: devzone workspace services disable %s\n", module, module)
		}
		return 2
	}
	if verb == "off" && (module == "postgres" || module == "mysql" || module == "gitlab") {
		if !m.confirmRemoval(module, extra) {
			return 0
		}
	}
	m.writeValue(module, verb)
	// Services held by Argo CD (#559): postgres and mysql, plus the release of
	// the Applications when argocd is turned off. Hook exit 0 is done by Argo CD,
	// 3 is the direct helm path, anything else is a failure.
	if module == "postgres" || module == "mysql" || (module == "argocd" && verb == "off") {
		code := m.call(m.ctx.Out, append([]string{"argocd", "services-hook", module, verb}, extra...)...)
		if code == 0 {
			return 0
		}
		if code != 3 {
			return 1
		}
	}
	// The assistant part of enable/disable ai is the Go command ai apply (#882).
	if module == "ai" {
		return m.call(m.ctx.Out, append([]string{"ai", "apply", verb}, extra...)...)
	}
	return m.applyModule(verb, module, extra)
}

// runEnable handles "devzone enable <module> [args]" in Go (change_module on).
func runEnable(ctx *cli.Context) int {
	return runModuleChange(ctx, "on")
}

// runDisable handles "devzone disable <module> [args]" in Go (change_module off).
func runDisable(ctx *cli.Context) int {
	return runModuleChange(ctx, "off")
}

func runModuleChange(ctx *cli.Context, verb string) int {
	module, extra := "", []string{}
	if len(ctx.Args) > 0 {
		module, extra = ctx.Args[0], ctx.Args[1:]
	}
	return newModules(ctx).changeModule(verb, module, extra)
}

// runIsEnabled handles "devzone is-enabled <module>": 0 when the module is on,
// 1 when it is off, without writing anything but the initial state (value_of).
func runIsEnabled(ctx *cli.Context) int {
	module := first(ctx.Args)
	if !isModule(module) {
		if module == "" {
			module = "(none)"
		}
		fmt.Fprintf(ctx.Err, "devzone : unknown module : %s\n", module)
		return 2
	}
	if newModules(ctx).value(module) == "on" {
		return 0
	}
	return 1
}
