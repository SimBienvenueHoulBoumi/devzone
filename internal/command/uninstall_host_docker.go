package command

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// dockerCall runs the Docker command of the host through the injected Runner.
// Only the Runner starts a process: tests give a fake one.
type dockerCall struct {
	ctx    context.Context
	runner exec.Runner
	cmd    string
}

// run runs docker with args. The error is non-nil when the command could not
// start or exited non-zero; the result keeps the output for the message.
func (d dockerCall) run(args ...string) (exec.Result, error) {
	res, err := d.runner.Run(d.ctx, d.cmd, args, exec.Opts{})
	if err == nil && res.Code != 0 {
		err = fmt.Errorf("exit %d", res.Code)
	}
	return res, err
}

// ok reports whether docker run with args succeeds.
func (d dockerCall) ok(args ...string) bool {
	_, err := d.run(args...)
	return err == nil
}

// lines returns the words of a successful call: container or volume ids. A
// failing call gives none, as the shell inventory did with "|| true".
func (d dockerCall) lines(args ...string) []string {
	res, err := d.run(args...)
	if err != nil {
		return nil
	}
	return strings.Fields(string(res.Stdout))
}

// text returns the trimmed output of a successful call, "" otherwise.
func (d dockerCall) text(args ...string) string {
	res, err := d.run(args...)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// uniqueSorted returns the distinct non-empty values, sorted.
func uniqueSorted(values []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, v := range values {
		if v != "" && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

// without returns values minus the ones in drop, keeping the order.
func without(values []string, drop ...[]string) []string {
	skip := map[string]bool{}
	for _, list := range drop {
		for _, v := range list {
			skip[v] = true
		}
	}
	out := []string{}
	for _, v := range values {
		if !skip[v] {
			out = append(out, v)
		}
	}
	return out
}

// folderContainers returns the containers created for this folder, with their
// image and their former internal Docker volume (installs before #291). The
// folder is searched under its logical and its physical path.
func folderContainers(d dockerCall, root string) (containers, images, dind []string) {
	paths := []string{root}
	if phys, err := filepath.EvalSymlinks(root); err == nil && phys != root {
		paths = append(paths, phys)
	}
	var ids []string
	for _, p := range paths {
		ids = append(ids, d.lines("ps", "-aq", "--filter", "label=devcontainer.local_folder="+p)...)
	}
	containers = uniqueSorted(ids)
	for _, id := range containers {
		images = append(images, d.text("inspect", id, "--format", "{{.Config.Image}}"))
		dind = append(dind, d.text("inspect", id, "--format", `{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}`))
	}
	return containers, uniqueSorted(images), uniqueSorted(dind)
}

// kindClusterContainers returns the containers of the instance kind clusters
// (devzone and gitlab): a kind cluster is nothing more than containers carrying
// its label on the host Docker.
func kindClusterContainers(d dockerCall, instance string) []string {
	suffix := ""
	if instance != "devzone" {
		suffix = "-" + instance
	}
	var ids []string
	for _, cluster := range []string{"devzone", "gitlab"} {
		ids = append(ids, d.lines("ps", "-aq", "--filter", "label=io.x-k8s.kind.cluster="+cluster+suffix)...)
	}
	return uniqueSorted(ids)
}

// labeledContainers returns the containers labeled devzone.instance=<instance>.
func labeledContainers(d dockerCall, instance string) []string {
	return uniqueSorted(d.lines("ps", "-aq", "--filter", "label=devzone.instance="+instance))
}

// stateImageAndDind reads IMAGE and DIND of the state file, the first match of
// each. The shell read them with sed, and never executed them.
func stateImageAndDind(path string) (image, dind string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if image == "" && strings.HasPrefix(line, "IMAGE=") {
			image = strings.TrimPrefix(line, "IMAGE=")
		}
		if dind == "" && strings.HasPrefix(line, "DIND=") {
			dind = strings.TrimPrefix(line, "DIND=")
		}
	}
	return image, dind
}
