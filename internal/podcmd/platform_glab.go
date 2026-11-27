package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// glabConnected reports whether glab is installed and connected to host.
func (p *platformCmd) glabConnected(host string) bool {
	return fileExists(p.glab) && commandOK(p.run(p.glab, "auth", "status", "--hostname", host))
}

// removeGlab removes glab and its configuration (back to GitHub).
func (p *platformCmd) removeGlab() {
	_ = os.Remove(p.glab)
	_ = os.RemoveAll(filepath.Join(p.m.home, ".config", "glab-cli"))
}

// installGlab installs glab from the official release, its SHA-256 sum checked;
// nothing when it is already there. The binary ends in ~/.local/bin.
func (p *platformCmd) installGlab() int {
	errOut := p.m.ctx.Err
	if fileExists(p.glab) && commandOK(p.run(p.glab, "--version")) {
		return 0
	}
	fmt.Fprintf(p.m.ctx.Out, "devzone : downloading glab %s (SHA-256 checked)…\n", glabVersion)
	archive, err := os.CreateTemp("", "glab-*.tar.gz")
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	archivePath := archive.Name()
	_ = archive.Close()
	defer os.Remove(archivePath)

	url := fmt.Sprintf("https://gitlab.com/gitlab-org/cli/-/releases/%s/downloads/glab_%s_linux_%s.tar.gz",
		glabVersion, strings.TrimPrefix(glabVersion, "v"), p.arch)
	if !commandOK(p.run("curl", "-fsSL", "-o", archivePath, url)) {
		fmt.Fprintln(errOut, "devzone : glab download failed (official gitlab.com release); retry: devzone platform gitlab --url URL")
		return 1
	}
	sumRes, sumErr := p.run("sha256sum", archivePath)
	sumGot := ""
	if commandOK(sumRes, sumErr) {
		sumGot = strings.SplitN(string(sumRes.Stdout), " ", 2)[0]
	}
	if sumGot != p.sum {
		fmt.Fprintln(errOut, "devzone : glab SHA-256 sum unexpected, aborting; archive refused")
		return 1
	}
	folder, err := os.MkdirTemp("", "glab-folder-*")
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	defer os.RemoveAll(folder)
	binary := filepath.Join(folder, "bin", "glab")
	if !commandOK(p.run("tar", "-xzf", archivePath, "-C", folder)) || !fileExists(binary) {
		binary = filepath.Join(folder, "glab")
	}
	if !fileExists(binary) {
		fmt.Fprintln(errOut, "devzone : glab binary missing from the archive, aborting")
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(p.glab), 0o755); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if err := moveFile(binary, p.glab); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if err := os.Chmod(p.glab, 0o755); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	return 0
}

// moveFile renames src to dst, copying it when the two folders are not on the same disk.
func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		return err
	}
	return os.Remove(src)
}

// connectGlab logs glab in to the GitLab instance: the instance of the gitlab
// module with its root token (never shown); another instance interactively,
// the browser asking for the login code. The connection is checked afterwards.
func (p *platformCmd) connectGlab(host, url string) int {
	errOut := p.m.ctx.Err
	if url == gitlabURLModule {
		tokenPath := filepath.Join(p.m.root, "workspace", ".gitlab", "root-token")
		if !fileExists(tokenPath) {
			fmt.Fprintf(errOut, "devzone : root token of the gitlab module not found (%s): devzone enable gitlab, or by hand: glab auth login --hostname %s\n", tokenPath, host)
			return 1
		}
		data, _ := os.ReadFile(tokenPath)
		token := strings.TrimRight(string(data), "\n")
		if !commandOK(p.runInteractive(p.glab, "auth", "login", "--hostname", host, "--api-protocol", "http", "--git-protocol", "http", "--token", token)) {
			fmt.Fprintf(errOut, "devzone : cannot connect to the gitlab instance: devzone enable gitlab, or by hand: glab auth login --hostname %s\n", host)
			return 1
		}
	} else if !commandOK(p.runInteractive(p.glab, "auth", "login", "--hostname", host)) {
		fmt.Fprintf(errOut, "devzone : cannot connect to the gitlab instance: glab auth login --hostname %s\n", host)
		return 1
	}
	if !commandOK(p.run(p.glab, "auth", "status", "--hostname", host)) {
		fmt.Fprintf(errOut, "devzone : cannot verify the connection: glab auth status --hostname %s\n", host)
		return 1
	}
	return 0
}
