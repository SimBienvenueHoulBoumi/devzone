package postgres

import (
	"context"
	"fmt"
	"strings"
)

// Authorize applies the isolating NetworkPolicy in ns and prints the access
// message of the shell module.
func Authorize(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 || args[0] == "" {
		if e.opts.Err != nil {
			fmt.Fprintln(e.opts.Err, "devzone postgres: namespace missing")
		}
		return 2
	}
	target := args[0]
	if err := e.kube.NamespaceIsolate(e.ctx, target, e.opts.Err); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.line("devzone postgres: access allowed from %s to the PostgreSQL service", target)
	return 0
}

// Forbid replaces the ingress rule of the isolating NetworkPolicy with the
// same-namespace-only rule, built with jq as in isolation.sh.
func Forbid(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 || args[0] == "" {
		if e.opts.Err != nil {
			fmt.Fprintln(e.opts.Err, "devzone postgres: namespace missing")
		}
		return 2
	}
	target := args[0]
	patch, err := e.exec("jq", []string{"-nc", `{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}`}, nil)
	if err != nil || patch.Code != 0 {
		e.showErr(patch)
		return 1
	}
	res, err := e.exec("kubectl", []string{
		"--context", "devzone", "-n", ns, "patch", "networkpolicy", "devzone-meme-namespace",
		"-p", strings.TrimSuffix(string(patch.Stdout), "\n")}, nil)
	if err != nil || res.Code != 0 {
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "devzone : postgres : cannot remove the access rule of %s: %s\n", target, strings.TrimSpace(string(res.Stderr)))
		}
		return 1
	}
	e.line("devzone postgres: access forbidden from %s to the PostgreSQL service", target)
	return 0
}

// RelayStart restarts the port-forward when the module is installed.
func RelayStart(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName := e.cluster()
	if ctxName != "" && e.installed(e.kube.AccountContext(ctxName)) {
		port := setting("POSTGRES_PORT", "5432")
		if err := relayStart(e, ctxName, port); err != nil {
			e.fail("%v", err)
			return 1
		}
	}
	return 0
}

// RelayStop stops the detached port-forward and removes its PID file.
func RelayStop(ctx context.Context, opts Options, args []string) int {
	newEnv(ctx, opts).stopRelay()
	return 0
}
