package postgres

import (
	"context"
	"strings"
)

// List prints the databases and their owners, excluding the system databases.
func List(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable postgres")
	}
	res, err := e.k("exec", "-i", "postgres-0", "-c", "postgres", "--", "psql",
		"-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres",
		"-At", "-F", " ", "-c", "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY 1")
	if err != nil || res.Code != 0 {
		e.showErr(res)
		return 1
	}
	count := 0
	for _, line := range strings.Split(strings.TrimSuffix(string(res.Stdout), "\n"), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		owner := ""
		if len(fields) > 1 {
			owner = fields[1]
		}
		e.line("  %-30s owner %s", fields[0], owner)
		count++
	}
	if count == 0 {
		e.line("  (no database: devzone postgres create <project>)")
	}
	return 0
}
