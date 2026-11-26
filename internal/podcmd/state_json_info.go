package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

// folderVersion reads the version written in the instance manifest.
func folderVersion(root string) (string, error) {
	data, err := os.ReadFile(filepath.Join(root, ".devzone.version"))
	if err != nil {
		return "", err
	}
	first := strings.SplitN(string(data), "\n", 2)[0]
	first = strings.TrimSuffix(first, "\n")
	if !strings.HasPrefix(first, "version ") {
		return "", os.ErrInvalid
	}
	v := strings.TrimPrefix(first, "version ")
	if v == "" {
		return "", os.ErrInvalid
	}
	return v, nil
}

// publishedVersion reads the cached published version, or queries the package
// registry through the configured tool and refreshes the cache.
func publishedVersion(d jsonDeps) string {
	home := os.Getenv("HOME")
	cache := filepath.Join(home, ".cache", "devzone", "version-publiee")
	day := time.Now().Format("2006-01-02")
	if data, err := os.ReadFile(cache); err == nil {
		lines := strings.Split(string(data), "\n")
		if len(lines) > 1 && strings.TrimSuffix(lines[0], "\r") == day {
			return strings.TrimSuffix(lines[1], "\r")
		}
	}
	npm := strings.TrimSpace(os.Getenv("DEVZONE_NPM"))
	if npm == "" {
		npm = "npm"
	}
	v := ""
	if out, _, err := d.run(npm, "view", "devzone", "version"); err == nil {
		v = strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}, out)
	}
	_ = os.MkdirAll(filepath.Dir(cache), 0o755)
	_ = os.WriteFile(cache, []byte(day+"\n"+v+"\n"), 0o644)
	return v
}

// devzoneJSON reports the folder and published versions of devzone.
func devzoneJSON(d jsonDeps, version string) jsonObject {
	return jsonObject{
		{key: "version", value: strOrNil(version)},
		{key: "available", value: strOrNil(publishedVersion(d))},
	}
}

// gitIdentityJSON reports the configured git name and email, or the login command.
func gitIdentityJSON(d jsonDeps) jsonObject {
	name, _, _ := d.run("git", "config", "--get", "user.name")
	email, _, _ := d.run("git", "config", "--get", "user.email")
	name = trimNewlines(name)
	email = trimNewlines(email)
	ok := name != "" && email != ""
	var command any
	if !ok {
		command = "gh auth login -s workflow (automatic), or git config --file ~/.config/git/config user.name \"<name>\" and user.email \"<email>\""
	}
	return jsonObject{
		{key: "ok", value: ok},
		{key: "name", value: strOrNil(name)},
		{key: "email", value: strOrNil(email)},
		{key: "command", value: command},
	}
}

// platformJSON reports the chosen platform, its URL and the GitHub connection.
func platformJSON(d jsonDeps, errs *jsonObject) jsonObject {
	platform := d.st.Get("platform")
	if platform != "gitlab" {
		platform = "github"
	}
	var url any
	if platform == "gitlab" {
		url = strOrNil(d.st.Get("gitlab_url"))
	}
	var github any
	if platform == "github" {
		out, code, err := d.runBoth("gh", "auth", "status")
		if err != nil || code != 0 {
			errs.set("github", "gh auth status failed")
		} else {
			workflow := true
			var command any
			if strings.Contains(out, "Token scopes:") && !strings.Contains(out, "'workflow'") {
				workflow = false
				command = "gh auth refresh -h github.com -s workflow"
			}
			github = jsonObject{
				{key: "connected", value: true},
				{key: "workflow", value: workflow},
				{key: "command", value: command},
			}
		}
	}
	return jsonObject{
		{key: "name", value: platform},
		{key: "url", value: url},
		{key: "github", value: github},
	}
}

// toolsJSON reports the tools whose installed version differs from the pinned one.
func toolsJSON(d jsonDeps, errs jsonObject) (jsonObject, jsonObject) {
	late := []any{}
	command := any(nil)
	versions := filepath.Clean(filepath.Join(d.code, "..", "manage", "scripts", "ci", "versions.sh"))
	var out string
	var code int
	var err error
	if _, statErr := os.Stat(versions); statErr != nil {
		err = statErr
	} else {
		out, code, err = d.run("bash", versions, "--installees")
	}
	if err != nil || code != 0 {
		errs.set("tools", "outdated_tools unavailable")
		return jsonObject{{key: "outdated", value: any(nil)}, {key: "command", value: command}}, errs
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		frozen := ""
		installed := ""
		if len(fields) > 1 {
			frozen = fields[1]
		}
		if len(fields) > 2 {
			installed = fields[2]
		}
		late = append(late, jsonObject{
			{key: "package", value: fields[0]},
			{key: "frozen", value: frozen},
			{key: "installed", value: installed},
		})
	}
	if len(late) > 0 {
		command = "devzone apply"
	}
	return jsonObject{{key: "outdated", value: late}, {key: "command", value: command}}, errs
}

// argocdRepo returns the GitOps repository declared for the argocd section.
func argocdRepo(root string) any {
	data, err := os.ReadFile(filepath.Join(root, ".argocd.conf"))
	if err != nil {
		return nil
	}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || section != "argocd" || strings.TrimSpace(key) != "repo" {
			continue
		}
		value = strings.TrimSpace(strings.SplitN(value, "#", 2)[0])
		if value != "" {
			return value
		}
	}
	return nil
}

// credentialsJSON returns the path of the grouped credentials, never their content.
func credentialsJSON(root string) any {
	path := filepath.Join(root, ".password")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	return nil
}
