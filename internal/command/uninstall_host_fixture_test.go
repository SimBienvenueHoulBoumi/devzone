package command

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// dindFormat is the --format of the former internal Docker volume of a container.
const dindFormat = `{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}`

// folderMounts is the devcontainer configuration of the folder: two volumes of
// the instance (one of the logins) and one bind mount, which is never removed.
const folderMounts = `{"configuration":{"mounts":["source=devzone-m2,target=/home/vscode/.m2,type=volume",` +
	`"source=devzone-gh,target=/home/vscode/.config/gh,type=volume",` +
	`{"source":"/host/path","target":"/x","type":"bind"}]}}`

// folderRunner programs the Docker and npx answers of a folder with one
// container (c1), its image, its former volume, a kind cluster (k1), a labeled
// container (l1) and two volumes. Every removal call succeeds. No real command
// runs: the Runner is the only way the host is read.
func folderRunner(t *testing.T, root string) *fake.Runner {
	t.Helper()
	runner := fake.New()
	runner.On("docker", []string{"info"}, exec.Result{})
	paths := []string{root}
	if phys, err := filepath.EvalSymlinks(root); err == nil && phys != root {
		paths = append(paths, phys)
	}
	for _, p := range paths {
		runner.On("docker", []string{"ps", "-aq", "--filter", "label=devcontainer.local_folder=" + p}, exec.Result{Stdout: []byte("c1\n")})
		runner.On("npx", []string{"-y", "@devcontainers/cli", "read-configuration", "--workspace-folder", p}, exec.Result{Stdout: []byte(folderMounts)})
	}
	runner.On("docker", []string{"inspect", "c1", "--format", "{{.Config.Image}}"}, exec.Result{Stdout: []byte("vsc-img\n")})
	runner.On("docker", []string{"inspect", "c1", "--format", dindFormat}, exec.Result{Stdout: []byte("dind-vol\n")})
	runner.On("docker", []string{"ps", "-aq", "--filter", "label=io.x-k8s.kind.cluster=devzone"}, exec.Result{Stdout: []byte("k1\n")})
	runner.On("docker", []string{"ps", "-aq", "--filter", "label=io.x-k8s.kind.cluster=gitlab"}, exec.Result{})
	runner.On("docker", []string{"ps", "-aq", "--filter", "label=devzone.instance=devzone"}, exec.Result{Stdout: []byte("c1\nl1\n")})
	runner.On("docker", []string{"volume", "inspect", "devzone-m2"}, exec.Result{})
	runner.On("docker", []string{"volume", "inspect", "devzone-gh"}, exec.Result{})
	runner.On("docker", []string{"network", "inspect", "kind"}, exec.Result{Stdout: []byte(`[{"Containers": {}}]`)})
	for _, args := range [][]string{
		{"rm", "-f", "c1"}, {"rmi", "vsc-img"}, {"volume", "rm", "dind-vol"},
		{"volume", "rm", "devzone-m2"}, {"volume", "rm", "devzone-gh"},
		{"rm", "-f", "k1"}, {"network", "rm", "kind"}, {"rm", "-f", "l1"},
	} {
		runner.On("docker", args, exec.Result{})
	}
	return runner
}

// dockerCalls returns the docker calls of the runner as "docker <args>" lines.
func dockerCalls(runner *fake.Runner) []string {
	var out []string
	for _, c := range runner.Calls() {
		if c.Name == "docker" {
			out = append(out, strings.Join(c.Args, " "))
		}
	}
	return out
}

// runUninstall runs the command in root with args and stdin, and returns the
// status and the two outputs.
func runUninstall(t *testing.T, runner *fake.Runner, root string, args []string, stdin string) (int, string, string) {
	t.Helper()
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: args, Out: &out, Err: &errOut, Stdin: strings.NewReader(stdin), Runner: runner})
	return code, out.String(), errOut.String()
}

// indexOf returns the index of v in list, -1 when absent.
func indexOf(list []string, v string) int {
	for i, s := range list {
		if s == v {
			return i
		}
	}
	return -1
}

// count returns how many times v appears in list.
func count(list []string, v string) int {
	n := 0
	for _, s := range list {
		if s == v {
			n++
		}
	}
	return n
}
