package cluster

import (
	"context"
	"encoding/json"
	"io"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/output"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// client holds the kubeconfig and the context of one clean run.
type client struct {
	ctx      context.Context
	api      kube.Kube
	conf     string
	cluster  string
	interval time.Duration
}

// kubectl runs kubectl on the services context with the admin kubeconfig.
func (c *client) kubectl(args ...string) (exec.Result, error) {
	return c.kubectlCtx(c.ctx, args...)
}

// kubectlCtx runs kubectl with a bounded context, used while waiting for a pod.
func (c *client) kubectlCtx(ctx context.Context, args ...string) (exec.Result, error) {
	all := append([]string{"--context", c.cluster}, args...)
	return c.api.Run(ctx, c.conf, all...)
}

// nodeNames returns the node names of the services cluster.
func (c *client) nodeNames() ([]string, error) {
	res, err := c.kubectl("get", "nodes", "-o", "name")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			names = append(names, strings.TrimPrefix(line, "node/"))
		}
	}
	return names, nil
}

// measurement is the free disk space reported by a node.
type measurement struct {
	Free      float64
	Available int64
	OK        bool
}

// measure reads the available and total bytes of a node from the stats API.
func (c *client) measure(node string) (measurement, error) {
	path := "/api/v1/nodes/" + node + "/proxy/stats/summary"
	res, err := c.kubectl("get", "--raw", path)
	if err != nil {
		return measurement{}, err
	}
	var summary struct {
		Node struct {
			FS struct {
				AvailableBytes int64 `json:"availableBytes"`
				CapacityBytes  int64 `json:"capacityBytes"`
			} `json:"fs"`
		} `json:"node"`
	}
	if res.Code != 0 || json.Unmarshal(res.Stdout, &summary) != nil || summary.Node.FS.CapacityBytes <= 0 {
		return measurement{}, nil
	}
	fs := summary.Node.FS
	return measurement{
		Free:      100 * float64(fs.AvailableBytes) / float64(fs.CapacityBytes),
		Available: fs.AvailableBytes,
		OK:        true,
	}, nil
}

// imageFor returns an image of the node that has a shell and may be pruned.
func (c *client) imageFor(node string) (string, error) {
	res, err := c.kubectl("get", "node", node, "-o", "json")
	if err != nil {
		return "", err
	}
	var detail struct {
		Status struct {
			Images []struct {
				Names []string `json:"names"`
			} `json:"images"`
		} `json:"status"`
	}
	if res.Code != 0 || json.Unmarshal(res.Stdout, &detail) != nil {
		return "", nil
	}
	var names []string
	for _, image := range detail.Status.Images {
		names = append(names, image.Names...)
	}
	return chooseImage(names), nil
}

// debug starts the node debug pod that prunes the unused images.
func (c *client) debug(node, image string) (string, error) {
	args := []string{
		"debug", "node/" + node, "--image=" + image, "--profile=sysadmin", "--",
		"chroot", "/host", "crictl", "--timeout=300s", "rmi", "--prune",
	}
	res, err := c.kubectl(args...)
	if err != nil || res.Code != 0 {
		return "", err
	}
	return podName(res.Stdout), nil
}

// cleanNode cleans one node and returns its report; a failed debug pod does not
// stop the other nodes.
func (c *client) cleanNode(name string, opts Options, out io.Writer) (NodeReport, error) {
	report := NodeReport{Name: name}
	before, err := c.measure(name)
	if err != nil {
		return report, err
	}
	report.FreeBefore = before.Free
	report.FreeAfter = before.Free
	if !before.OK {
		output.Warn(out, "cluster clean: cannot measure disk on %s", name)
		report.Failed = true
		return report, nil
	}
	if before.Free >= cleanThreshold {
		return report, nil
	}
	image, err := c.imageFor(name)
	if err != nil {
		return report, err
	}
	report.Image = image
	if image == "" {
		output.Warn(out, "cluster clean: no usable image on %s", name)
		report.Failed = true
		report.Low = before.Free < lowThreshold
		if report.Low {
			output.Warn(out, "cluster disk: %.1f%% free on %s after cleaning: enlarge the disk of the local cluster", before.Free, name)
		}
		return report, nil
	}
	if opts.DryRun {
		if !opts.Quiet {
			output.Info(out, "cluster clean [dry-run]: would clean %s with %s at %.1f%% free", name, image, before.Free)
		}
		report.Low = before.Free < lowThreshold
		if report.Low {
			output.Warn(out, "cluster disk: %.1f%% free on %s after cleaning: enlarge the disk of the local cluster", before.Free, name)
		}
		return report, nil
	}
	pod, err := c.debug(name, image)
	if err != nil {
		return report, err
	}
	if pod == "" {
		output.Warn(out, "cluster clean: debug pod not created on %s", name)
		report.Failed = true
		report.Low = before.Free < lowThreshold
		return report, nil
	}
	defer func() { _, _ = c.kubectl("delete", "pod", pod, "--ignore-not-found", "--wait=false") }()
	phase, err := c.waitPod(pod)
	if err != nil {
		return report, err
	}
	logs, err := c.kubectl("logs", pod)
	if err != nil {
		return report, err
	}
	report.Deleted = deletedLines(logs.Stdout)
	if phase == "Failed" {
		output.Warn(out, "cluster clean: debug pod failed on %s", name)
		report.Failed = true
	}
	after, err := c.measure(name)
	if err != nil {
		return report, err
	}
	report.FreeAfter = after.Free
	if after.OK && after.Available > before.Available {
		report.FreedBytes = after.Available - before.Available
	}
	if !opts.Quiet {
		output.OK(out, "cluster clean: %.1f GB freed on %s", float64(report.FreedBytes)/1e9, name)
	}
	if after.OK {
		report.Low = after.Free < lowThreshold
	} else {
		report.Low = before.Free < lowThreshold
	}
	if report.Low {
		output.Warn(out, "cluster disk: %.1f%% free on %s after cleaning: enlarge the disk of the local cluster", report.FreeAfter, name)
	}
	return report, nil
}
