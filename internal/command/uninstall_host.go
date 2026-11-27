package command

import (
	"context"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// hostPlan lists what this folder left on the host: Docker containers, images
// and volumes, the kind clusters and labeled containers of the instance, and the
// metrics-server devzone installed on host clusters. It is read before anything
// is removed, and printed before the confirmation.
type hostPlan struct {
	inside         bool     // inside the pod: the host Docker is not inventoried
	stateFile      bool     // .devzone.state exists
	containers     []string // containers created for this folder
	images         []string // their images (or the image named by the state file)
	dind           []string // former internal Docker volumes (installs before #291)
	volumes        []string // devcontainer volumes of the instance
	kept           []string // volumes kept by KEEP (logins)
	kindClusters   []string // containers of the instance kind clusters
	labeled        []string // containers labeled devzone.instance=<instance>
	metrics        []string // host contexts whose metrics-server devzone installed
	foreign        []string // host contexts whose metrics-server it did not install
	kubectlMissing bool     // kubectl is not on the host: host clusters not checked
	manifest       string   // metrics-server manifest URL of the pinned version
}

// count returns the number of host resources to remove (kept volumes excluded).
func (h hostPlan) count() int {
	return len(h.containers) + len(h.images) + len(h.dind) + len(h.volumes) +
		len(h.kindClusters) + len(h.labeled) + len(h.metrics)
}

// collectHostPlan reads the host resources of the folder. Docker inventory
// failures count as nothing found, as the shell did; only an unreadable
// devcontainer configuration stops the command.
func collectHostPlan(ctx context.Context, runner exec.Runner, root, instance, keep string, inside bool) (hostPlan, error) {
	h := hostPlan{inside: inside}
	if _, err := os.Stat(filepath.Join(root, stateFileName)); err == nil {
		h.stateFile = true
	}
	if !inside {
		if err := h.inventoryDocker(dockerCall{ctx: ctx, runner: runner, cmd: dockerCommand()}, root, instance, keep); err != nil {
			return hostPlan{}, err
		}
	}
	h.metrics, h.foreign, h.kubectlMissing = findMetricsServers(ctx, runner)
	h.manifest = metricsManifestURL(root)
	return h, nil
}

// inventoryDocker fills the Docker part of the plan. Containers come first; the
// state file names the image and the volume of a folder whose container is gone.
// Each list keeps a resource in one place only, so a removal never runs twice.
func (h *hostPlan) inventoryDocker(d dockerCall, root, instance, keep string) error {
	h.containers, h.images, h.dind = folderContainers(d, root)
	if len(h.containers) == 0 && h.stateFile {
		image, dind := stateImageAndDind(filepath.Join(root, stateFileName))
		if image != "" && d.ok("image", "inspect", image) {
			h.images = uniqueSorted(append(h.images, image))
		}
		if dind != "" && d.ok("volume", "inspect", dind) {
			h.dind = uniqueSorted(append(h.dind, dind))
		}
	}
	h.kindClusters = without(kindClusterContainers(d, instance), h.containers)
	h.labeled = without(labeledContainers(d, instance), h.containers, h.kindClusters)
	names, err := devcontainerVolumes(d.ctx, d.runner, root)
	if err != nil {
		return err
	}
	for _, name := range names {
		if !d.ok("volume", "inspect", name) {
			continue
		}
		if keepsLogins(keep, name) {
			h.kept = append(h.kept, name)
			continue
		}
		h.volumes = append(h.volumes, name)
	}
	h.volumes = without(h.volumes, h.dind)
	return nil
}
