package cluster

import (
	"context"
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/output"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

const (
	cleanThreshold = 15.0
	lowThreshold   = 5.0
)

// Clean prunes unused images on every node of the local services cluster. A
// missing cluster choice, a pod run or a distant cluster is not an error: those
// cases are reported and return the normal status.
func Clean(ctx context.Context, opts Options) (Report, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	report := Report{DryRun: opts.DryRun}
	out := opts.Out
	if out == nil {
		out = io.Discard
	}
	root := opts.Root
	if root == "" {
		root = os.Getenv("DEVZONE_ROOT")
	}
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			return report, err
		}
	}
	name, ok := state.New(root).GetOK("cluster")
	report.Context = name
	if !ok || name == "" {
		return report, nil
	}
	if os.Getenv("DEVZONE_WORKSPACE") == "kubernetes" {
		if !opts.Quiet {
			output.Info(out, "cluster clean: skipped inside the workspace pod")
		}
		report.Skipped = true
		return report, nil
	}
	runner := opts.Runner
	if runner == nil {
		runner = exec.ExecRunner{}
	}
	api := kube.Kube{Runner: runner}
	if !api.IsLocal(name) {
		if !opts.Quiet {
			output.Info(out, "cluster clean: skipped, cluster %s is not local", name)
		}
		report.Skipped = true
		return report, nil
	}
	c := &client{
		ctx:      ctx,
		api:      api,
		conf:     api.AdminKubeconfig(name),
		cluster:  name,
		interval: opts.PollInterval,
	}
	nodes, err := c.nodeNames()
	if err != nil {
		return report, err
	}
	minFree := 100.0
	anyBelow := false
	for _, node := range nodes {
		nodeReport, err := c.cleanNode(node, opts, out)
		if err != nil {
			return report, err
		}
		report.Nodes = append(report.Nodes, nodeReport)
		report.FreedBytes += nodeReport.FreedBytes
		if nodeReport.Low {
			report.Code = 3
		}
		if nodeReport.FreeBefore < minFree {
			minFree = nodeReport.FreeBefore
		}
		if nodeReport.FreeBefore < cleanThreshold {
			anyBelow = true
		}
	}
	if !opts.Quiet && len(nodes) > 0 && !anyBelow {
		output.Info(out, "cluster disk: %.1f%% free, nothing to clean", minFree)
	}
	return report, nil
}
