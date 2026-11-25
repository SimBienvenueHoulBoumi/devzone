package postgres

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

var projectName = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)

// Create creates the role, the database with access revoked from PUBLIC, and
// the 600 credentials file kept for an existing project.
func Create(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 {
		return e.fail("project name missing")
	}
	project := args[0]
	if !e.validateProject(project) {
		return 2
	}
	renew := false
	for _, arg := range args[1:] {
		if arg == "--new-password" {
			renew = true
			continue
		}
		return e.fail("unknown argument: %s", arg)
	}
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable postgres")
	}
	file := filepath.Join(e.secrets, project+".env")
	password := ""
	if data, err := os.ReadFile(file); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "DB_PASSWORD=") {
				password = strings.TrimSuffix(strings.TrimPrefix(line, "DB_PASSWORD="), "\r")
				break
			}
		}
	}
	if password == "" || renew {
		var err error
		password, err = e.newPassword()
		if err != nil {
			e.fail("%v", err)
			return 1
		}
	}
	script := fmt.Sprintf(`SELECT 'CREATE ROLE %s LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s')\gexec
ALTER ROLE %s PASSWORD '%s';
SELECT 'CREATE DATABASE %s OWNER %s' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '%s')\gexec
REVOKE CONNECT ON DATABASE %s FROM PUBLIC;
GRANT CONNECT ON DATABASE %s TO %s;
`, project, project, project, password, project, project, project, project, project, project)
	res, err := e.psqlAdmin(strings.NewReader(script))
	if err != nil || res.Code != 0 {
		e.show(res)
		return 1
	}
	e.show(res)
	port := setting("POSTGRES_PORT", "5432")
	content := fmt.Sprintf(`DB_HOST=127.0.0.1
DB_PORT=%s
DB_NAME=%s
DB_USER=%s
DB_PASSWORD=%s
DB_URL=jdbc:postgresql://127.0.0.1:%s/%s
`, port, project, project, password, port, project)
	if err := writeCredentials(e.secrets, file, content); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ database %s ready; credentials: %s", project, file)
	e.regenerate()
	return 0
}

// validateProject refuses a name that is not a simple SQL identifier, or a
// reserved PostgreSQL name, as validate_project of the shell module does.
func (e *env) validateProject(project string) bool {
	if project == "" {
		e.fail("project name missing")
		return false
	}
	if !projectName.MatchString(project) {
		e.fail("invalid project name: %s (lowercase, digits, _; starts with a letter)", project)
		return false
	}
	switch project {
	case "postgres", "template0", "template1":
		e.fail("reserved name: %s", project)
		return false
	}
	return true
}

// psqlAdmin runs a SQL script as superuser in the postgres pod through stdin.
func (e *env) psqlAdmin(stdin io.Reader) (exec.Result, error) {
	res, err := e.kInput(stdin, "exec", "-i", "postgres-0", "-c", "postgres", "--", "psql",
		"-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres")
	return res, err
}

// writeCredentials writes a project .env file with mode 600 in a 700 folder.
func writeCredentials(dir, path, content string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}
