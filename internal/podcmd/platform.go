package podcmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// glabVersion is the pinned glab release (gitlab.com/gitlab-org/cli). The
// binary is installed only when the gitlab platform is chosen.
const glabVersion = "v1.126.0"

// glabSumARM64 and glabSumAMD64 are the SHA-256 sums of the release archives;
// the archive is refused when its sum differs.
const (
	glabSumARM64 = "de5e92c9c8b306eeebb19daa854d48101b78328850e7b9cd677ecd6f98cd4391"
	glabSumAMD64 = "f386519ba83e9482979992ee7f60eeebee4d95b950f95f4fe7289e0a1b1ea74c"
)

// gitlabURLModule is the URL of the GitLab instance of the gitlab module.
const gitlabURLModule = "http://gitlab.localhost:8929"

// platformCmd runs the platform commands: GitHub (default) or GitLab (#240).
// The choice is kept in the state file (platform=, gitlab_url=); glab lives in
// ~/.local/bin and every call goes through its path, never through PATH.
type platformCmd struct {
	m    *modules
	glab string // path of the glab binary
	arch string // release archive of this machine: arm64 or amd64
	sum  string // SHA-256 sum of the archive for arch
}

// newPlatformCmd builds the platform commands on the folders and the Runner of the pod.
func newPlatformCmd(ctx *cli.Context) *platformCmd {
	m := newModules(ctx)
	p := &platformCmd{
		m:    m,
		glab: filepath.Join(m.home, ".local", "bin", "glab"),
		arch: "amd64",
		sum:  glabSumAMD64,
	}
	if runtime.GOARCH == "arm64" {
		p.arch, p.sum = "arm64", glabSumARM64
	}
	return p
}

// run runs an external command with the Runner of the context and captures its output.
func (p *platformCmd) run(name string, args ...string) (fexec.Result, error) {
	return p.m.ctx.Runner.Run(context.Background(), name, args, fexec.Opts{})
}

// runInteractive runs a command whose prompts go to the terminal (glab login).
func (p *platformCmd) runInteractive(name string, args ...string) (fexec.Result, error) {
	return p.m.ctx.Runner.Run(context.Background(), name, args, fexec.Opts{Stdin: p.m.ctx.Stdin, Inherit: true})
}

// commandOK reports whether a command ran and exited with 0.
func commandOK(res fexec.Result, err error) bool {
	return err == nil && res.Code == 0
}

// platformRead returns "gitlab" when the platform is gitlab, else "github" (the default).
func (p *platformCmd) platformRead() string {
	if state.At(p.m.etat).Get("platform") == "gitlab" {
		return "gitlab"
	}
	return "github"
}

// gitlabURLRead returns the URL of the GitLab instance kept in the state, "" if missing.
func (p *platformCmd) gitlabURLRead() string {
	return state.At(p.m.etat).Get("gitlab_url")
}

// glabConnected reports whether glab is installed and connected to host.
func (p *platformCmd) glabConnected(host string) bool {
	return fileExists(p.glab) && commandOK(p.run(p.glab, "auth", "status", "--hostname", host))
}

// removeGlab removes glab and its configuration (back to GitHub).
func (p *platformCmd) removeGlab() {
	_ = os.Remove(p.glab)
	_ = os.RemoveAll(filepath.Join(p.m.home, ".config", "glab-cli"))
}

// platformSummary prints the current platform (devzone platform).
func (p *platformCmd) platformSummary() int {
	out := p.m.ctx.Out
	if p.platformRead() != "gitlab" {
		fmt.Fprintln(out, "devzone : github platform (default)")
		return 0
	}
	url := p.gitlabURLRead()
	host := gitlabHost(url)
	if p.glabConnected(host) {
		fmt.Fprintf(out, "devzone : gitlab platform: %s, glab connected\n", url)
	} else {
		fmt.Fprintf(out, "devzone : gitlab platform: %s, glab not connected: glab auth login --hostname %s\n", url, host)
	}
	return 0
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

// changePlatform switches the platform: github (default) or gitlab with its URL.
func (p *platformCmd) changePlatform(args []string) int {
	out, errOut := p.m.ctx.Out, p.m.ctx.Err
	target := args[0]
	switch target {
	case "github":
		// Removes the credential setting of the last gitlab host, if there is one
		if url := p.gitlabURLRead(); url != "" {
			_, _ = p.run("git", "config", "--global", "--unset-all", "credential."+url+".helper")
		}
		p.removeGlab()
		if p.m.removeKey("platform") != 0 || p.m.removeKey("gitlab_url") != 0 {
			return 1
		}
		fmt.Fprintln(out, "devzone : github platform (default): gh checks; glab and its configuration removed if they were installed")
		return 0
	case "gitlab":
		return p.changeToGitlab(args[1:])
	}
	fmt.Fprintf(errOut, "devzone : unknown platform: %s; choices: github (default) or gitlab [--url URL]\n", target)
	return 1
}

// changeToGitlab parses "gitlab [--url URL]", installs and connects glab, sets
// the git credential helper and keeps the platform in the state.
func (p *platformCmd) changeToGitlab(args []string) int {
	out, errOut := p.m.ctx.Out, p.m.ctx.Err
	url, expect := "", false
	for _, arg := range args {
		if expect {
			url, expect = arg, false
			continue
		}
		switch arg {
		case "--url":
			expect = true
		default:
			fmt.Fprintf(errOut, "devzone : unknown argument: %s (devzone platform gitlab --url URL)\n", arg)
			return 1
		}
	}
	if expect {
		fmt.Fprintln(errOut, "devzone : --url expects a URL")
		return 1
	}
	if url == "" {
		if p.m.value("gitlab") != "on" {
			fmt.Fprintln(errOut, "devzone : missing URL: devzone platform gitlab --url URL (or an active gitlab module for the local instance)")
			return 1
		}
		url = gitlabURLModule
	}
	host := gitlabHost(url)
	if p.installGlab() != 0 {
		return 1
	}
	if p.connectGlab(host, url) != 0 {
		fmt.Fprintf(errOut, "devzone : reconnect needed: glab auth login --hostname %s\n", host)
		return 1
	}
	if !commandOK(p.run("git", "config", "--global", "credential."+url+".helper", "!"+p.glab+" auth git-credential")) {
		fmt.Fprintln(errOut, "devzone : cannot set the git credential")
		return 1
	}
	if p.m.writeValue("platform", "gitlab") != 0 || p.m.writeValue("gitlab_url", url) != 0 {
		return 1
	}
	fmt.Fprintf(out, "devzone : gitlab platform: %s, glab connected\n", url)
	return 0
}

// runPlatform handles "devzone platform [github|gitlab [--url URL]]" in Go.
func runPlatform(ctx *cli.Context) int {
	p := newPlatformCmd(ctx)
	if len(ctx.Args) == 0 || ctx.Args[0] == "" {
		return p.platformSummary()
	}
	return p.changePlatform(ctx.Args)
}
