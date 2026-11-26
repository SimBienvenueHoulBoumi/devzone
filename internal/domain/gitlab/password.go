package gitlab

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// tabSep is the separator of the .password entries (service, address, user,
// password).
const tabSep = "\t"

// readFileNoNl reads a file like a shell command substitution (trailing
// newlines stripped), empty when missing or unreadable.
func readFileNoNl(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}

// readEnvKey returns the last value of "key=" in a .env file, like the
// sed/tail pipeline of the shell scripts.
func readEnvKey(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	value := ""
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, prefix); ok {
			value = v
		}
	}
	return value
}

// listFiles returns the names of the files of dir (the glob of the shell),
// empty when the dir is absent.
func listFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return out
}

// listDirs returns the names of the directories of dir, like "$root/workspace/.*/".
func listDirs(dir string) []string {
	var out []string
	for _, name := range listFiles(dir) {
		path := dir + "/" + name
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			out = append(out, name)
		}
	}
	return out
}

// appendSecret appends a "service\taddress\tuser\tsecret" line to entries,
// like the printf of password_regenerate; nothing when user or secret is empty.
func appendSecret(entries *[]string, service, address, user, secret string) {
	if user == "" || secret == "" {
		return
	}
	*entries = append(*entries, strings.Join([]string{service, address, user, secret}, tabSep))
}

// sortEntries sorts the entries like `LC_ALL=C sort -t tab -k1,1 -k3,3`: by
// service then by user (fields 1 and 3 of the entry).
func sortEntries(entries []string) {
	fields := func(line string) [3]string {
		parts := strings.SplitN(line, tabSep, 3)
		var out [3]string
		for i, p := range parts {
			if i < 3 {
				out[i] = p
			}
		}
		return out
	}
	sort.Slice(entries, func(i, j int) bool {
		a, b := fields(entries[i]), fields(entries[j])
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		return a[2] < b[2]
	})
}

// regeneratePasswords regenerates the grouped .password of the root from the
// folders of the workspace (port of password_regenerate of
// .devcontainer/password.sh): silent on success; without any account, the
// file is removed. 0 on success, 1 when the file could not be written.
func (r *run) regeneratePasswords() int {
	root := r.root
	gl := root + "/workspace/.gitlab"
	pg := root + "/workspace/.postgres"
	ar := root + "/workspace/.argocd"
	my := root + "/workspace/.mysql"
	var entries []string

	appendSecret(&entries, "gitlab", "http://gitlab.localhost:8929", "root", readFileNoNl(gl+"/root-password"))
	appendSecret(&entries, "gitlab", "http://gitlab.localhost:8929", "dev", readFileNoNl(gl+"/dev-password"))
	appendSecret(&entries, "postgres", "127.0.0.1:5432", "postgres", readFileNoNl(pg+"/admin-password"))
	appendSecret(&entries, "mysql", "127.0.0.1:3306", "root", readFileNoNl(my+"/admin-password"))
	argocdUser := readEnvKey(ar+"/admin.env", "ARGOCD_USER")
	argocdSecret := readEnvKey(ar+"/admin.env", "ARGOCD_PASSWORD")
	appendSecret(&entries, "argocd", "https://127.0.0.1:8443", argocdUser, argocdSecret)

	for _, name := range listFiles(pg) {
		if !strings.HasSuffix(name, ".env") {
			continue
		}
		base := strings.TrimSuffix(name, ".env")
		user := firstNonEmpty(readEnvKey(pg+"/"+name, "DB_USER"))
		secret := firstNonEmpty(readEnvKey(pg+"/"+name, "DB_PASSWORD"))
		if user == "" || secret == "" {
			continue
		}
		address := firstNonEmpty(readEnvKey(pg+"/"+name, "DB_NAME"))
		if address == "" {
			address = base
		}
		appendSecret(&entries, "postgres:"+base, "127.0.0.1:5432/"+address, user, secret)
	}

	for _, app := range listDirs(root + "/workspace") {
		if app == ".gitlab" || app == ".postgres" || app == ".argocd" || app == ".mysql" {
			continue
		}
		appUpper := strings.ToUpper(app)
		dir := root + "/workspace/" + app
		for _, name := range listFiles(dir) {
			if !strings.HasSuffix(name, ".env") {
				continue
			}
			path := dir + "/" + name
			base := strings.TrimSuffix(name, ".env")
			user := firstNonEmpty(readEnvKey(path, appUpper+"_USER"), readEnvKey(path, "DB_USER"), readEnvKey(path, "MYSQL_USER"))
			secret := firstNonEmpty(readEnvKey(path, appUpper+"_PASSWORD"), readEnvKey(path, "DB_PASSWORD"), readEnvKey(path, "MYSQL_PASSWORD"))
			if user == "" || secret == "" {
				continue
			}
			host := firstNonEmpty(readEnvKey(path, appUpper+"_HOST"), readEnvKey(path, "DB_HOST"), readEnvKey(path, "MYSQL_HOST"))
			if host == "" {
				host = "127.0.0.1"
			}
			port := firstNonEmpty(readEnvKey(path, appUpper+"_PORT"), readEnvKey(path, "DB_PORT"), readEnvKey(path, "MYSQL_PORT"))
			if port == "" {
				port = "3306"
			}
			appendSecret(&entries, app+":"+base, host+":"+port, user, secret)
		}
	}

	if len(entries) == 0 {
		_ = os.Remove(root + "/.password")
		return 0
	}
	sortEntries(entries)
	header := "# devzone : identifiers of the accounts created by devzone. Plain-text secrets:\n" +
		"# never commit, copy or paste them into a ticket. Regenerated by devzone.\n" +
		"# service" + tabSep + "address" + tabSep + "user" + tabSep + "password\n"
	data := header
	for _, e := range entries {
		data += e + "\n"
	}
	target := filepath.Join(root, ".password")
	if err := os.WriteFile(target, []byte(data), 0o600); err != nil {
		return 1
	}
	_ = os.Chmod(target, 0o600)
	return 0
}

// firstNonEmpty returns the first non-empty value of the list.
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
