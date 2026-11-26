package cluster

import (
	"context"
	"fmt"
	"strings"
)

// Use handles "devzone use CTX [-n NS] [--confirm CTX]": it switches the
// working kubectl context without touching the saved services cluster, as
// use_cluster did.
func Use(ctx context.Context, opts ManageOptions, args []string) int {
	if ctx == nil {
		ctx = context.Background()
	}
	name, namespace, confirm := "", "", ""
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "-n" || arg == "--namespace" || arg == "--confirm":
			if i+1 >= len(args) {
				if arg == "--confirm" {
					fmt.Fprintln(opts.errOut(), "devzone : --confirm expects a context")
				} else {
					fmt.Fprintf(opts.errOut(), "devzone : %s expects a namespace\n", arg)
				}
				return 2
			}
			i++
			if arg == "--confirm" {
				confirm = args[i]
			} else {
				namespace = args[i]
			}
		case strings.HasPrefix(arg, "--namespace="):
			namespace = strings.TrimPrefix(arg, "--namespace=")
		case strings.HasPrefix(arg, "--confirm="):
			confirm = strings.TrimPrefix(arg, "--confirm=")
		case strings.HasPrefix(arg, "-"):
			fmt.Fprintf(opts.errOut(), "devzone : unknown argument: %s (devzone use CTX [-n NS] [--confirm CTX])\n", arg)
			return 2
		case name == "":
			name = arg
		default:
			fmt.Fprintf(opts.errOut(), "devzone : unknown argument: %s (devzone use CTX [-n NS] [--confirm CTX])\n", arg)
			return 2
		}
	}
	k := opts.newKube()
	if name == "" {
		if namespace == "" {
			fmt.Fprintln(opts.errOut(), "devzone : missing context: devzone use CTX")
			return 2
		}
		name = k.CurrentContext(ctx)
		if name == "" {
			fmt.Fprintln(opts.errOut(), "devzone : no current context")
			return 2
		}
	}
	names, err := k.ConfigContexts(ctx)
	if err != nil {
		fmt.Fprintln(opts.errOut(), err)
		return 1
	}
	if !hasExact(names, name) {
		fmt.Fprintf(opts.errOut(), "devzone : unknown context: %s (see kubectl config get-contexts)\n", name)
		return 2
	}
	current := k.CurrentContext(ctx)
	if name != current {
		if !k.IsLocal(name) {
			if confirm == "" && opts.isInteractive() {
				fmt.Fprintf(opts.errOut(), "remote cluster: %s; type its name to confirm: ", name)
				confirm = opts.answer()
			}
			if confirm != name {
				fmt.Fprintf(opts.errOut(), "devzone : remote cluster refused: %s (--confirm %s)\n", name, name)
				return 2
			}
		}
		if err := k.UseContext(ctx, name); err != nil {
			fmt.Fprintln(opts.errOut(), err)
			return 1
		}
	}
	if namespace != "" {
		if err := k.SetNamespace(ctx, name, namespace); err != nil {
			fmt.Fprintln(opts.errOut(), err)
			return 1
		}
	}
	fmt.Fprintf(opts.out(), "working cluster: %s\n", name)
	if namespace != "" {
		fmt.Fprintf(opts.out(), "namespace: %s\n", namespace)
	}
	return 0
}

// hasExact reports whether names contains value as a whole line.
func hasExact(names []string, value string) bool {
	for _, name := range names {
		if name == value {
			return true
		}
	}
	return false
}
