package kube

import (
	"context"
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"io"
	"strings"
)

// View prints the table of connected clusters with the working and services
// marks and the NetworkPolicy state, as clusters_show did.
func (k Kube) View(ctx context.Context, saved string, out, errOut io.Writer) int {
	working := k.CurrentContext(ctx)
	names, err := k.ConfigContexts(ctx)
	if err != nil {
		fmt.Fprintln(errOutOrDiscard(errOut), err)
		return 1
	}
	if len(names) == 0 {
		fmt.Fprintln(errOutOrDiscard(out), "no cluster: kind create cluster, or devzone enable kubernetes")
		return 0
	}
	fmt.Fprintf(errOutOrDiscard(out), "%s %-14s %-8s %-12s %s\n", "  ", "CONTEXT", "TYPE", "STATE", "NAMESPACE")
	for _, name := range names {
		state := "unreachable"
		if k.ClusterReachable(ctx, name) {
			state = "reachable"
		}
		typ := "remote"
		if k.IsLocal(name) {
			typ = "local"
		}
		ns := k.ContextNamespace(ctx, name)
		if ns == "" {
			ns = "default"
		}
		mark := ""
		if name == working {
			mark += "★"
		}
		if name == saved {
			mark += "●"
		}
		mark += strings.Repeat(" ", 2-len([]rune(mark)))
		fmt.Fprintf(errOutOrDiscard(out), "%s %-14s %-8s %-12s %s\n", mark, name, typ, state, ns)
	}
	fmt.Fprintln(errOutOrDiscard(out))
	fmt.Fprintln(errOutOrDiscard(out), "★ working cluster (kubectl, k9s, helm) · ● devzone services cluster (devzone cluster)")
	if saved != "" && k.IsLocal(saved) {
		res, err := k.raw(ctx, "--context", saved, "get", "networkpolicy", "devzone-meme-namespace", "-n", config.NamespacePostgres)
		if err == nil && res.Code == 0 {
			fmt.Fprintf(errOutOrDiscard(out), "  ✔ isolated (NetworkPolicy) → %s\n", saved)
		} else {
			fmt.Fprintf(errOutOrDiscard(out), "  ⚠ isolated (NetworkPolicy missing) → %s\n", saved)
		}
		fmt.Fprintf(errOutOrDiscard(out), "  devzone → %s\n", saved)
	}
	return 0
}
