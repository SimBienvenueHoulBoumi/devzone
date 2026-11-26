package gitlab

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// pushDemoProject pushes the content of .devcontainer/gitlab/demo to
// devzone/demo in a throwaway repository. The root token is read by a Git
// credential helper from its 600 file: it is never an argument nor in a URL.
func (r *run) pushDemoProject() int {
	token, ok := r.readSecret(r.rootTokenFile())
	if !ok {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : root token not found, seed stopped.")
		return 1
	}
	if r.apiOK(token, "/api/v4/projects/devzone%2Fdemo/repository/branches/main") {
		fmt.Fprintln(r.out(), "✔ GitLab seed complete (demo project already pushed).")
		r.regeneratePasswords()
		return 0
	}
	demoDir := r.root + "/.devcontainer/gitlab/demo"
	if info, err := os.Stat(demoDir); err != nil || !info.IsDir() {
		fmt.Fprintln(r.out(), "✔ GitLab seed complete.")
		r.regeneratePasswords()
		return 0
	}
	tmpdir, err := os.MkdirTemp("", "devzone-gitlab-demo")
	if err != nil {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : temporary directory impossible.")
		return 1
	}
	defer os.RemoveAll(tmpdir)
	if err := copyDir(demoDir, tmpdir); err != nil {
		fmt.Fprintf(r.errOut(), "devzone : seed GitLab : copy of the demo project failed, seed stopped.\n%v\n", err)
		return 1
	}
	if err := r.gitPushDemo(tmpdir); err != nil {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : push of the demo project to /devzone/demo.git failed, seed stopped.")
		return 1
	}
	if !r.apiOK(token, "/api/v4/projects/devzone%2Fdemo/repository/branches/main") {
		fmt.Fprintln(r.errOut(), "devzone : seed GitLab : push of the demo project to /devzone/demo.git succeeded but branch main is missing, seed stopped.")
		return 1
	}
	fmt.Fprintln(r.out(), "✔ GitLab seed complete.")
	r.regeneratePasswords()
	return 0
}

// gitPushDemo runs the Git calls of the demo push through the runner of the
// framework. The credential helper reads the token file; no argument holds a
// secret, and no real process is started by a test.
func (r *run) gitPushDemo(dir string) error {
	helper := "!f() { echo username=oauth2; printf 'password='; cat \"" + r.rootTokenFile() + "\"; echo; }; f"
	remote := "http://127.0.0.1:8929/devzone/demo.git"
	runGit := func(args ...string) error {
		res, err := r.runner().Run(r.ctx, "git", args, exec.Opts{Dir: dir,
			Env: []string{"GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null'"}})
		if err != nil {
			return err
		}
		if res.Code != 0 {
			return fmt.Errorf("git %s: code %d", args[0], res.Code)
		}
		return nil
	}
	if err := runGit("init", "-q", "-b", "main"); err != nil {
		return err
	}
	if err := runGit("add", "-A"); err != nil {
		return err
	}
	if err := runGit("-c", "user.email=dev@gitlab.localhost", "-c", "user.name=dev",
		"commit", "-q", "-m", "chore: demo project"); err != nil {
		return err
	}
	if err := runGit("remote", "add", "origin", remote); err != nil {
		return err
	}
	return runGit("-c", "credential.helper=", "-c", "credential.helper="+helper,
		"-c", "http.extraHeader=Host: gitlab.localhost", "push", "-q", "-u", "origin", "main")
}

// copyDir copies the content of src into the existing dir, preserving the
// mode of the entries and the hidden files, like the cp -r of the seed.
func copyDir(src, dir string) error {
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			return err
		}
		if e.IsDir() {
			if err := os.MkdirAll(dir+"/"+e.Name(), info.Mode().Perm()); err != nil {
				return err
			}
			if err := copyDir(src+"/"+e.Name(), dir+"/"+e.Name()); err != nil {
				return err
			}
			continue
		}
		data, err := os.ReadFile(src + "/" + e.Name())
		if err != nil {
			return err
		}
		if err := os.WriteFile(dir+"/"+e.Name(), data, info.Mode().Perm()); err != nil {
			return err
		}
	}
	return nil
}
