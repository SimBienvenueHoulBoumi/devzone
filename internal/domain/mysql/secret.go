package mysql

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// mysqlSecret keeps the root secret of the cluster, or creates it from
// root.env / the local file / a new password. It is never regenerated.
func (e *env) mysqlSecret() error {
	if err := os.MkdirAll(e.secrets, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(e.secrets, 0o700); err != nil {
		return err
	}
	file := filepath.Join(e.secrets, "admin-password")
	if res, err := e.k("get", "secret", "mysql-admin"); err == nil && res.Code == 0 {
		data, err := e.k("get", "secret", "mysql-admin", "-o", "jsonpath={.data.password}")
		if err != nil {
			return err
		}
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data.Stdout)))
		if err != nil {
			return err
		}
		return writeSecret(file, []byte(strings.TrimSpace(string(decoded))))
	}
	password := readEnvValue(filepath.Join(e.secrets, "root.env"), "MYSQL_PASSWORD")
	if password == "" {
		if data, err := os.ReadFile(file); err == nil {
			password = strings.TrimSpace(string(data))
		}
	}
	if password == "" {
		password, err := e.newPassword()
		if err != nil {
			return err
		}
		if err := writeSecret(file, []byte(password)); err != nil {
			return err
		}
		res, err := e.k("create", "secret", "generic", "mysql-admin", "--from-file=password="+file)
		if err != nil {
			return err
		}
		if res.Code != 0 {
			e.showErr(res)
			return errors.New("cannot create the mysql-admin secret")
		}
		return nil
	}
	return writeSecret(file, []byte(password))
}

// newPassword generates a password with the same command as the shell module.
func (e *env) newPassword() (string, error) {
	res, err := e.exec("openssl", []string{"rand", "-hex", "24"}, nil)
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return "", errors.New("openssl rand failed")
	}
	return strings.TrimSpace(string(res.Stdout)), nil
}

// readEnvValue returns the last value of key in an env file.
func readEnvValue(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	found := ""
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, prefix) {
			found = strings.TrimSuffix(strings.TrimPrefix(line, prefix), "\r")
		}
	}
	return found
}

// writeSecret writes a secret file with mode 600.
func writeSecret(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// relayStart keeps the MySQL port-forward alive on the chosen cluster.
func (e *env) relayStart(ctxName, namespace string) {
	if err := relay.Start(e.secrets, "mysql", ctxName, namespace, "svc/mysql",
		[]string{"3306:3306"}, e.opts.Launcher); err != nil {
		e.fail("%v", err)
	}
}
