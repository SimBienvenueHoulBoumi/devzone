package podcmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// runApplyRepowarden restores the pinned repowarden version and reinstalls its
// global hooks, as the apply step of the removed repair library did.
func runApplyRepowarden(ctx *cli.Context) int {
	versions := filepath.Join(codeRoot(), "..", "manage", "scripts", "ci", "versions.sh")
	if _, err := os.Stat(versions); err != nil {
		return 0
	}
	out, code, err := (jsonDeps{ctx: ctx}).run("bash", versions, "--installees")
	if err != nil || code != 0 {
		return 0
	}
	pinned, installed, found := repowardenVersions(out)
	if !found {
		return 0
	}
	fmt.Fprintf(ctx.Out, "devzone : installing repowarden %s…\n", pinned)
	res, err := ctx.Runner.Run(context.Background(), "npm",
		[]string{"install", "-g", "repowarden@" + pinned}, exec.Opts{})
	if err != nil || res.Code != 0 {
		writeRunOutput(ctx, res)
		return 1
	}
	if len(res.Stderr) > 0 {
		_, _ = io.WriteString(ctx.Err, string(res.Stderr))
	}
	res, err = ctx.Runner.Run(context.Background(), "repowarden",
		[]string{"install", "--global", "--lang", "fr"}, exec.Opts{})
	writeRunOutput(ctx, res)
	if err != nil || res.Code != 0 {
		return 1
	}
	fmt.Fprintf(ctx.Out, "devzone : repowarden %s → %s\n", installed, pinned)
	return 0
}

// repowardenVersions extracts the pinned and installed versions from the
// installed-tools listing, ignoring every other package line.
func repowardenVersions(listing string) (pinned, installed string, found bool) {
	for _, line := range strings.Split(listing, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "repowarden" {
			continue
		}
		if len(fields) > 1 {
			pinned = fields[1]
		}
		if len(fields) > 2 {
			installed = fields[2]
		}
		return pinned, installed, true
	}
	return "", "", false
}

// writeRunOutput forwards a command's captured streams without changing them.
func writeRunOutput(ctx *cli.Context, res exec.Result) {
	if len(res.Stdout) > 0 {
		_, _ = io.WriteString(ctx.Out, string(res.Stdout))
	}
	if len(res.Stderr) > 0 {
		_, _ = io.WriteString(ctx.Err, string(res.Stderr))
	}
}
