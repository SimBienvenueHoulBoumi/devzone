package postgres

import (
	"context"
	"strings"
)

// Status prints one line: disabled, failed, ready without relay, or ready with
// the relay address and the number of project databases.
func Status(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName := e.cluster()
	if ctxName == "" || !e.installed(e.kube.AccountContext(ctxName)) {
		e.line("disabled")
		return 0
	}
	res, err := e.k("get", "statefulset", "postgres", "-o", "jsonpath={.status.readyReplicas}")
	if err != nil || strings.TrimSpace(string(res.Stdout)) != "1" {
		e.line("failed on %s: devzone apply", ctxName)
		return 0
	}
	if !e.relayActive() {
		e.line("ready on %s, relay stopped: devzone apply", ctxName)
		return 0
	}
	e.line("ready on %s: 127.0.0.1:%s, %s database(s)", ctxName, setting("POSTGRES_PORT", "5432"), e.databaseCount())
	return 0
}

// databaseCount counts the databases outside the system ones; a failed query
// is shown as "?" without blocking the status, as in the shell module.
func (e *env) databaseCount() string {
	res, err := e.k("exec", "-i", "postgres-0", "-c", "postgres", "--", "psql",
		"-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres",
		"-At", "-c", "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')")
	if err != nil || res.Code != 0 {
		return "?"
	}
	return strings.TrimSpace(string(res.Stdout))
}
