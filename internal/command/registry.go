package command

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// Registry is the single registry of commands for this binary.
var Registry = newDefaultRegistry()

// newDefaultRegistry builds the registry with the commands ported to Go.
func newDefaultRegistry() *cli.Registry {
	r := cli.NewRegistry()
	for _, name := range []string{"--version", "-v"} {
		n := name
		r.Register(cli.Command{
			Name: n,
			Bare: true,
			Run:  func(ctx *cli.Context) int { return printVersion(ctx.Out) },
			Delegate: func(ctx *cli.Context) int {
				return delegate(append([]string{n}, ctx.Args...), ctx.Out, ctx.Err)
			},
		})
	}
	for _, name := range []string{"help", "-h", "--help"} {
		n := name
		r.Register(cli.Command{
			Name: n,
			Bare: true,
			Run:  func(ctx *cli.Context) int { return printHelp(ctx.Out) },
			Delegate: func(ctx *cli.Context) int {
				return delegate(append([]string{n}, ctx.Args...), ctx.Out, ctx.Err)
			},
		})
	}
	r.Register(cli.Command{
		Name: "workspace",
		Run:  workspaceCommand,
	})
	r.Register(cli.Command{
		Name: "uninstall",
		Run:  uninstallCommand,
	})
	r.Register(cli.Command{
		Name: "update",
		Run:  updateCommand,
	})
	r.Register(cli.Command{
		Name: "cluster-offer",
		Run:  clusterOfferCommand,
	})
	r.Register(cli.Command{
		Name: "host-check",
		Run:  hostCheckCommand,
	})
	return r
}

// Ported returns the names of the commands implemented in Go, sorted.
func Ported() []string {
	return Registry.Names()
}
