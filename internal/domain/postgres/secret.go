package postgres

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/passwords"
)

// newPassword generates a password with the same command as the shell module,
// so a fake openssl can make the tests deterministic.
func (e *env) newPassword() (string, error) {
	res, err := e.exec("openssl", []string{"rand", "-hex", "24"}, nil)
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return "", fmt.Errorf("openssl rand: exit %d", res.Code)
	}
	return strings.TrimSpace(string(res.Stdout)), nil
}

// adminSecret keeps the superuser secret of the cluster, or creates it from
// the local file / a new password. It is never regenerated on an existing
// installation: the database keeps its own password.
func (e *env) adminSecret() error {
	if err := os.MkdirAll(e.secrets, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(e.secrets, 0o700); err != nil {
		return err
	}
	file := filepath.Join(e.secrets, "admin-password")
	if res, err := e.k("get", "secret", "postgres-admin"); err == nil && res.Code == 0 {
		data, err := e.k("get", "secret", "postgres-admin", "-o", "jsonpath={.data.password}")
		if err != nil {
			return err
		}
		if data.Code != 0 {
			return errors.New("cannot read the postgres-admin secret")
		}
		decoded, err := base64Decode(strings.TrimSpace(string(data.Stdout)))
		if err != nil {
			return err
		}
		return writeSecret(file, decoded)
	}
	existing, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if len(existing) == 0 {
		password, err := e.newPassword()
		if err != nil {
			return err
		}
		if err := writeSecret(file, []byte(password)); err != nil {
			return err
		}
	}
	res, err := e.k("create", "secret", "generic", "postgres-admin", "--from-file=password="+file)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		e.showErr(res)
		return errors.New("cannot create the postgres-admin secret")
	}
	return nil
}

// regenerate rebuilds the grouped credentials view with the shared Go library,
// without invoking a shell or passing a secret to a process (#881).
func (e *env) regenerate() {
	if e.codeRoot == "" {
		return
	}
	if err := passwords.Regenerate(filepath.Dir(e.codeRoot)); err != nil {
		if e.opts.Err != nil {
			fmt.Fprintln(e.opts.Err, "devzone : postgres : grouped credentials not updated (devzone passwords)")
		}
	}
}

// writeSecret writes a secret file with mode 600.
func writeSecret(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// base64Decode decodes the value of a Kubernetes secret.
func base64Decode(value string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(value)
}
