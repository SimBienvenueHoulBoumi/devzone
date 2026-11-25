package mysql

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var projectName = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)

// Create creates the user and the database of a project, with a 600 credentials
// file. An existing password is kept unless --new-password is asked.
func Create(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 {
		return e.fail("missing project name")
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
		return e.fail("module disabled: devzone enable mysql")
	}
	file := filepath.Join(e.secrets, project+".env")
	password := ""
	if !renew {
		if data, err := os.ReadFile(file); err == nil && len(data) > 0 {
			password = readEnvValue(file, "MYSQL_PASSWORD")
		}
	}
	if password == "" {
		var err error
		password, err = e.newPassword()
		if err != nil {
			e.fail("%v", err)
			return 1
		}
	}
	script := fmt.Sprintf(`CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';
ALTER USER '%s'@'%%' IDENTIFIED BY '%s';
CREATE DATABASE IF NOT EXISTS %s;
GRANT ALL ON %s.* TO '%s'@'%%';
`, project, password, project, password, project, project, project)
	res, err := e.mysqlAdmin([]string{}, strings.NewReader(script))
	if err != nil {
		e.fail("%v", err)
		return 1
	}
	if res.Code != 0 {
		e.show(res)
		return 1
	}
	e.show(res)
	port := setting("MYSQL_PORT", "3306")
	content := fmt.Sprintf(`MYSQL_HOST=127.0.0.1
MYSQL_PORT=%s
MYSQL_USER=%s
MYSQL_PASSWORD=%s
MYSQL_URL=jdbc:mysql://127.0.0.1:%s/%s
`, port, project, password, port, project)
	if err := writeEnvFile(e.secrets, file, content); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ database %s ready; credentials: %s", project, file)
	e.regenerate()
	return 0
}

// validateProject refuses a name that is not a simple SQL identifier, or a
// reserved MySQL name.
func (e *env) validateProject(project string) bool {
	if project == "" {
		e.fail("missing project name")
		return false
	}
	if !projectName.MatchString(project) {
		e.fail("invalid project name: %s (lowercase, digits, _; starts with a letter)", project)
		return false
	}
	switch project {
	case "mysql", "information_schema", "performance_schema", "sys":
		e.fail("reserved name: %s", project)
		return false
	}
	return true
}

// List prints the project databases, excluding the system databases.
func List(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable mysql")
	}
	res, err := e.mysqlAdmin([]string{"-N", "-B", "-e", "SHOW DATABASES"}, nil)
	if err != nil {
		e.fail("%v", err)
		return 1
	}
	if res.Code != 0 {
		e.showErr(res)
		return 1
	}
	count := 0
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		name := strings.Fields(line)
		if len(name) == 0 || systemDatabase(name[0]) {
			continue
		}
		e.line("  %-30s", name[0])
		count++
	}
	if count == 0 {
		e.line("  (no database: devzone mysql create <project>)")
	}
	return 0
}

// Delete drops the database and the user of a project, and removes its .env.
func Delete(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 {
		return e.fail("missing project name")
	}
	project := args[0]
	if !e.validateProject(project) {
		return 2
	}
	yes := false
	for _, arg := range args[1:] {
		if arg == "--yes" {
			yes = true
			continue
		}
		return e.fail("unknown argument: %s", arg)
	}
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable mysql")
	}
	if !yes {
		if !e.interactive() {
			return e.fail("confirmation needs a terminal: devzone mysql delete %s --yes", project)
		}
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "Delete database %s and its user? [y/N] ", project)
		}
		switch e.answer() {
		case "y", "Y", "yes":
		default:
			e.line("Aborted: nothing was deleted.")
			return 0
		}
	}
	script := fmt.Sprintf("DROP DATABASE IF EXISTS %s;\nDROP USER IF EXISTS '%s'@'%%';\n", project, project)
	res, err := e.mysqlAdmin([]string{}, strings.NewReader(script))
	if err != nil {
		e.fail("%v", err)
		return 1
	}
	if res.Code != 0 {
		e.show(res)
		return 1
	}
	e.show(res)
	if err := os.Remove(filepath.Join(e.secrets, project+".env")); err != nil && !os.IsNotExist(err) {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ database %s deleted", project)
	e.regenerate()
	return 0
}

// writeEnvFile writes a project .env file with mode 600 in a 700 folder.
func writeEnvFile(dir, path, content string) error {
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
