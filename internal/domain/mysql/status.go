package mysql

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Status prints the state of the module: disabled, failed, relay stopped, or
// ready with the relay address and the number of project databases.
func Status(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName := e.cluster()
	if ctxName == "" || !e.installed(e.activeAdminContext()) {
		e.line("disabled")
		return 0
	}
	res, err := e.k("get", "statefulset", "mysql", "-o", "jsonpath={.status.readyReplicas}")
	if err != nil || strings.TrimSpace(string(res.Stdout)) != "1" {
		e.line("failed on %s: devzone apply", ctxName)
		return 0
	}
	if !e.relayActive() {
		e.line("ready on %s, relay stopped: devzone apply", ctxName)
		return 0
	}
	e.line("ready on %s: 127.0.0.1:%s, %s database(s)", ctxName, setting("MYSQL_PORT", "3306"), e.databaseCount())
	return 0
}

// databaseCount counts the databases outside the MySQL system databases.
func (e *env) databaseCount() string {
	res, err := e.mysqlAdmin([]string{"-N", "-B", "-e", "SHOW DATABASES"}, nil)
	if err != nil || res.Code != 0 {
		return "0"
	}
	count := 0
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		name := strings.TrimSpace(line)
		if name == "" || systemDatabase(name) {
			continue
		}
		count++
	}
	return fmt.Sprint(count)
}

// systemDatabase reports whether name is one of the MySQL system databases.
func systemDatabase(name string) bool {
	switch name {
	case "information_schema", "mysql", "performance_schema", "sys":
		return true
	}
	return false
}

// rootPassword reads the root password from root.env or admin-password; it is
// never displayed.
func (e *env) rootPassword() (string, error) {
	password := readEnvValue(filepath.Join(e.secrets, "root.env"), "MYSQL_PASSWORD")
	if password == "" {
		if data, err := os.ReadFile(filepath.Join(e.secrets, "admin-password")); err == nil {
			password = strings.TrimSpace(string(data))
		}
	}
	if password == "" {
		return "", errors.New("MySQL root password not found (workspace/.mysql/root.env)")
	}
	return password, nil
}

// mysqlAdmin runs mysql as root in the pod, with the password on the command
// line as in the shell module; nothing is ever written to the output.
func (e *env) mysqlAdmin(args []string, stdin io.Reader) (exec.Result, error) {
	password, err := e.rootPassword()
	if err != nil {
		e.fail("%v", err)
	}
	full := append([]string{"exec", "-i", "mysql-0", "-c", "mysql", "--", "mysql", "-uroot", "-p" + password}, args...)
	return e.kInput(stdin, full...)
}
