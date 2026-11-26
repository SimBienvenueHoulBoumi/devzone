package passwords

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// tabSep separates the four fields of a credentials entry: service, address,
// user and password.
const tabSep = "\t"

// readFileNoNl reads a file like the shell command substitution: missing or
// unreadable files give an empty value and trailing newlines are stripped.
func readFileNoNl(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}

// readEnvKey returns the last value assigned to key in an .env file, as the
// sed and tail pipeline of the former shell library did.
func readEnvKey(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	value := ""
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, prefix); ok {
			value = v
		}
	}
	return value
}

// listNames returns the entries of dir in file-name order, like the shell glob.
func listNames(dir string) []string {
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		names = append(names, item.Name())
	}
	sort.Strings(names)
	return names
}

// appendEntry adds one credentials line when both the user and the secret are
// present, so an account without credentials is never written.
func appendEntry(entries *[]string, service, address, user, secret string) {
	if user == "" || secret == "" {
		return
	}
	*entries = append(*entries, strings.Join([]string{service, address, user, secret}, tabSep))
}

// firstNonEmpty returns the first non-empty value of values.
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

// collect reads every module and catalogue folder and returns the unsorted
// credentials entries in the same order as the former shell library.
func collect(root string) []string {
	workspace := filepath.Join(root, "workspace")
	gl := filepath.Join(workspace, ".gitlab")
	pg := filepath.Join(workspace, ".postgres")
	ar := filepath.Join(workspace, ".argocd")
	my := filepath.Join(workspace, ".mysql")
	var entries []string
	appendEntry(&entries, "gitlab", "http://gitlab.localhost:8929", "root", readFileNoNl(filepath.Join(gl, "root-password")))
	appendEntry(&entries, "gitlab", "http://gitlab.localhost:8929", "dev", readFileNoNl(filepath.Join(gl, "dev-password")))
	appendEntry(&entries, "postgres", "127.0.0.1:5432", "postgres", readFileNoNl(filepath.Join(pg, "admin-password")))
	appendEntry(&entries, "mysql", "127.0.0.1:3306", "root", readFileNoNl(filepath.Join(my, "admin-password")))
	appendEntry(&entries, "argocd", "https://127.0.0.1:8443",
		readEnvKey(filepath.Join(ar, "admin.env"), "ARGOCD_USER"),
		readEnvKey(filepath.Join(ar, "admin.env"), "ARGOCD_PASSWORD"))
	collectPostgres(&entries, pg)
	collectApps(&entries, workspace)
	return entries
}

// collectPostgres adds one entry per database .env file of the postgres folder.
func collectPostgres(entries *[]string, pg string) {
	for _, name := range listNames(pg) {
		if !strings.HasSuffix(name, ".env") {
			continue
		}
		path := filepath.Join(pg, name)
		base := strings.TrimSuffix(name, ".env")
		user := firstNonEmpty(readEnvKey(path, "DB_USER"))
		secret := firstNonEmpty(readEnvKey(path, "DB_PASSWORD"))
		if user == "" || secret == "" {
			continue
		}
		db := firstNonEmpty(readEnvKey(path, "DB_NAME"), base)
		appendEntry(entries, "postgres:"+base, "127.0.0.1:5432/"+db, user, secret)
	}
}

// collectApps adds the entries of the hidden catalogue folders other than the
// four modules handled above, accepting <APP>_*, DB_* and MYSQL_* keys.
func collectApps(entries *[]string, workspace string) {
	for _, name := range listNames(workspace) {
		if !strings.HasPrefix(name, ".") || name == ".gitlab" || name == ".postgres" || name == ".argocd" {
			continue
		}
		dir := filepath.Join(workspace, name)
		if info, err := os.Stat(dir); err != nil || !info.IsDir() {
			continue
		}
		upper := strings.ToUpper(strings.TrimPrefix(name, "."))
		for _, file := range listNames(dir) {
			if !strings.HasSuffix(file, ".env") {
				continue
			}
			path := filepath.Join(dir, file)
			base := strings.TrimSuffix(file, ".env")
			user := firstNonEmpty(readEnvKey(path, upper+"_USER"), readEnvKey(path, "DB_USER"), readEnvKey(path, "MYSQL_USER"))
			secret := firstNonEmpty(readEnvKey(path, upper+"_PASSWORD"), readEnvKey(path, "DB_PASSWORD"), readEnvKey(path, "MYSQL_PASSWORD"))
			if user == "" || secret == "" {
				continue
			}
			host := firstNonEmpty(readEnvKey(path, upper+"_HOST"), readEnvKey(path, "DB_HOST"), readEnvKey(path, "MYSQL_HOST"), "127.0.0.1")
			port := firstNonEmpty(readEnvKey(path, upper+"_PORT"), readEnvKey(path, "DB_PORT"), readEnvKey(path, "MYSQL_PORT"), "3306")
			appendEntry(entries, strings.TrimPrefix(name, ".")+":"+base, host+":"+port, user, secret)
		}
	}
}
