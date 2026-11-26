package argocd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const appsNS = "devzone-argocd"

// appsUsage prints app usage and returns 2.
func appsUsage(errOut io.Writer, cmd string) int {
	fmt.Fprintf(errOut, "usage: %s add <repo url> [path] [--name N] [--revision R] [--namespace NS] [--token T] [--username U] | list | remove <N>\n", cmd)
	return 2
}

// appsNameFromURL derives an app name from a repository URL.
func appsNameFromURL(url string) string {
	n := strings.TrimSuffix(url, "/")
	n = filepath.Base(n)
	n = strings.TrimSuffix(n, ".git")
	n = strings.ToLower(n)
	var b strings.Builder
	for _, c := range n {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			b.WriteRune(c)
		} else {
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	return out
}

// appsNameValid reports whether name is a valid app name.
func appsNameValid(name string) bool {
	if name == "" || len(name) > 40 || strings.HasPrefix(name, "-") {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			continue
		}
		return false
	}
	return true
}

// appsIsDevzoneGitLab reports whether url points to the local devzone GitLab.
func appsIsDevzoneGitLab(url string) bool {
	for _, p := range []string{"http://gitlab.localhost:8929/", "http://gitlab.localhost/", "https://gitlab.localhost/"} {
		if strings.HasPrefix(url, p) {
			return true
		}
	}
	return strings.HasPrefix(url, "https://gitlab.localhost:") && strings.Contains(url, "/")
}

// appsRepoInternal rewrites local GitLab URLs to the cluster-internal service URL.
func appsRepoInternal(url, gitlabNS string) string {
	if !appsIsDevzoneGitLab(url) {
		return url
	}
	path := url[strings.Index(url, "://")+3:]
	path = path[strings.Index(path, "/"):]
	if strings.HasPrefix(path, ":") {
		path = "/" + strings.SplitN(path[1:], "/", 2)[1]
	}
	if gitlabNS == "" {
		gitlabNS = "devzone-gitlab"
	}
	return "http://gitlab-webservice-default." + gitlabNS + ".svc:8181" + path
}

// appsGitLabNS returns the GitLab namespace for this instance.
func (m *module) appsGitLabNS() string {
	suffix := instanceSuffix()
	return "devzone-gitlab" + suffix
}

// instanceSuffix returns the devzone instance suffix like cluster.sh.
func instanceSuffix() string {
	inst := os.Getenv("DEVZONE_INSTANCE")
	if inst == "" || inst == "devzone" {
		return ""
	}
	return "-" + inst
}

// appsTokenOf resolves the token for an app repository.
func (m *module) appsTokenOf(tokenFile, repo string) string {
	if tokenFile != "" {
		file := tokenFile
		if !filepath.IsAbs(file) {
			file = filepath.Join(m.root, tokenFile)
		}
		data, err := os.ReadFile(file)
		if err == nil {
			return strings.TrimSpace(string(data))
		}
		return ""
	}
	if !appsIsDevzoneGitLab(repo) {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(m.root, "workspace", ".gitlab", "root-token"))
	if err == nil {
		return strings.TrimSpace(string(data))
	}
	return ""
}

// appsAdd implements "app add ...".
func (m *module) appsAdd(args []string) int {
	cmd := "devzone argocd app"
	repo, path, name, revision, namespace, token, username := "", "", "", "", "", "", ""
	pos := 0
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--name", "--revision", "--namespace", "--token", "--username":
			if i+1 >= len(args) {
				fmt.Fprintf(m.errOut, "✖ %s add: %s needs a value\n", cmd, arg)
				return 2
			}
			i++
			val := args[i]
			switch arg {
			case "--name":
				name = val
			case "--revision":
				revision = val
			case "--namespace":
				namespace = val
			case "--token":
				token = val
			case "--username":
				username = val
			}
		default:
			if strings.HasPrefix(arg, "-") {
				fmt.Fprintf(m.errOut, "✖ %s add: unknown option: %s\n", cmd, arg)
				return appsUsage(m.errOut, cmd)
			}
			pos++
			if pos == 1 {
				repo = arg
			} else if pos == 2 {
				path = arg
			} else {
				fmt.Fprintf(m.errOut, "✖ %s add: unexpected argument: %s\n", cmd, arg)
				return appsUsage(m.errOut, cmd)
			}
		}
	}
	if repo == "" {
		return appsUsage(m.errOut, cmd)
	}
	if !(strings.HasPrefix(repo, "https://") || strings.HasPrefix(repo, "http://") || strings.HasPrefix(repo, "ssh://") || strings.HasPrefix(repo, "git@")) {
		fmt.Fprintf(m.errOut, "✖ %s add: repository URL expected (https://…): %s\n", cmd, repo)
		return 2
	}
	if name == "" {
		name = appsNameFromURL(repo)
	}
	if !appsNameValid(name) {
		fmt.Fprintf(m.errOut, "✖ %s add: invalid name: %s (lowercase letters, digits, dashes, 40 at most: --name N)\n", cmd, displayAppName(name))
		return 2
	}
	if appsIsDevzoneGitLab(repo) && token == "" && m.appsTokenOf("", repo) == "" {
		fmt.Fprintf(m.errOut, "✖ %s add: token of the devzone GitLab not found (workspace/.gitlab/root-token): --token T\n", cmd)
		return 2
	}
	if path == "" {
		path = "."
	}
	if revision == "" {
		revision = "HEAD"
	}
	if namespace == "" {
		namespace = "devzone-app-" + name
	}
	pairs := []string{"repo=" + repo, "path=" + path, "revision=" + revision, "namespace=" + namespace}
	if username != "" {
		pairs = append(pairs, "username="+username)
	}
	if token != "" {
		tokenFile := "workspace/.argocd/tokens/" + name
		dir := filepath.Join(m.root, "workspace", ".argocd", "tokens")
		_ = os.MkdirAll(dir, 0o700)
		_ = os.Chmod(filepath.Join(m.root, "workspace", ".argocd"), 0o700)
		_ = os.Chmod(dir, 0o700)
		if err := writeFile0600(filepath.Join(m.root, tokenFile), []byte(token)); err != nil {
			fmt.Fprintln(m.errOut, err)
			return 1
		}
		pairs = append(pairs, "token-file="+tokenFile)
	}
	if err := m.conf().Set("app "+name, pairs...); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if code := m.appsApplyOne(name); code != 0 {
		return code
	}
	fmt.Fprintf(m.out, "  declared in %s; sync status: %s list\n", m.confPath(), cmd)
	return 0
}

// displayAppName formats an invalid app name for error messages.
func displayAppName(name string) string {
	if name == "" {
		return "(empty)"
	}
	return name
}
