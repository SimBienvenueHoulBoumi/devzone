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
	for _, name := range []string{"help", "-h", "--help"} {
		r.Register(cli.Command{
			Name: name,
			Run:  printHelp,
		})
	}
	r.Register(cli.Command{
		Name: "agent",
		Run:  runAgent,
	})
	r.Register(cli.Command{
		Name: "subreaper",
		Run:  runSubreaper,
	})
	r.Register(cli.Command{
		Name: "ai",
		Run:  runAI,
	})
	r.Register(cli.Command{
		Name: "ticket",
		Run:  runTicket,
	})
	r.Register(cli.Command{
		Name: "repair",
		Run:  runRepair,
	})
	r.Register(cli.Command{
		Name: "services-admin",
		Run:  runServicesAdmin,
	})
	r.Register(cli.Command{
		Name:    "status",
		Aliases: []string{"", "modules"},
		Run:     runStatus,
	})
	r.Register(cli.Command{
		Name: "version-available-line",
		Run:  versionAvailableLine,
	})
	r.Register(cli.Command{
		Name: "apply-repowarden",
		Run:  runApplyRepowarden,
	})
	r.Register(cli.Command{
		Name: "cluster",
		Run:  runCluster,
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
		Name: "metrics",
		Run:  runMetrics,
	})
	r.Register(cli.Command{
		Name: "gitlab",
		Run:  runGitlab,
	})
	r.Register(cli.Command{
		Name: "test-gitlab",
		Run:  runTestGitlab,
	})
	r.Register(cli.Command{
		Name: "state",
		Run:  runState,
	})
	r.Register(cli.Command{
		Name: "passwords",
		Run:  runPasswords,
	})
	r.Register(cli.Command{
		Name: "port",
		Run:  runPort,
	})
	r.Register(cli.Command{
		Name: "packages",
		Run:  runPackages,
	})
	r.Register(cli.Command{
		Name: "catalog",
		Run:  runCatalog,
	})
	r.Register(cli.Command{
		Name: "catalog-watcher",
		Run:  runCatalogWatcher,
	})
	r.Register(cli.Command{
		Name: "clusters",
		Run:  runClusters,
	})
	r.Register(cli.Command{
		Name: "use",
		Run:  runUse,
	})
	r.Register(cli.Command{
		Name: "kube",
		Run:  runKube,
	})
	r.Register(cli.Command{
		Name: "enable",
		Run:  runEnable,
	})
	r.Register(cli.Command{
		Name: "disable",
		Run:  runDisable,
	})
	r.Register(cli.Command{
		Name: "is-enabled",
		Run:  runIsEnabled,
	})
	r.Register(cli.Command{
		Name: "apply",
		Run:  runApply,
	})
	r.Register(cli.Command{
		Name: "platform",
		Run:  runPlatform,
	})
	return r
}

// Ported returns the names of the commands implemented in Go, sorted.
func Ported() []string {
	return Registry.Names()
}
