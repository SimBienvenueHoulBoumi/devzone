package podcmd

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// Registry is the single registry of commands for this binary.
var Registry = newDefaultRegistry()

// newDefaultRegistry builds the registry with the commands ported to Go.
func newDefaultRegistry() *cli.Registry {
	r := cli.NewRegistry()
	for _, name := range []string{"--version", "-v"} {
		r.Register(cli.Command{
			Name: name,
			Run:  printVersion,
		})
	}
	r.Register(cli.Command{
		Name: "ticket",
		Run:  runTicket,
	})
	r.Register(cli.Command{
		Name: "cluster",
		Run:  runCluster,
	})
	r.Register(cli.Command{
		Name: "account",
		Run:  runAccount,
	})
	r.Register(cli.Command{
		Name: "postgres",
		Run:  runPostgres,
	})
	r.Register(cli.Command{
		Name: "mysql",
		Run:  runMysql,
	})
	r.Register(cli.Command{
		Name: "argocd",
		Run:  runArgocd,
	})
	r.Register(cli.Command{
		Name: "gitlab",
		Run:  runGitlab,
	})
	r.Register(cli.Command{
		Name: "test-gitlab",
		Run:  runTestGitlab,
	})
	return r
}

// Ported returns the names of the commands implemented in Go, sorted.
func Ported() []string {
	return Registry.Names()
}
