package ai

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Pinned assistant packages, kept in sync with the launcher declarations.
const (
	claudePackage   = "@anthropic-ai/claude-code@2.1.332"
	opencodePackage = "opencode-ai@1.19.6"
)

// binaryOf returns the binary that proves an assistant package was installed.
func binaryOf(pkg string) string {
	if len(pkg) >= 11 && pkg[:11] == "opencode-ai" {
		return "opencode"
	}
	return "claude"
}

// runWithProgress runs a command and announces a long wait at each interval.
func runWithProgress(ctx context.Context, o Options, name string, args []string) dzexec.Result {
	step := 30
	if value := os.Getenv("DEVZONE_PROGRESS"); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil && parsed > 0 {
			step = parsed
		}
	}
	type outcome struct {
		res dzexec.Result
		err error
	}
	ch := make(chan outcome, 1)
	go func() {
		res, err := o.runner().Run(ctx, name, args, dzexec.Opts{})
		ch <- outcome{res, err}
	}()
	ticker := time.NewTicker(time.Duration(step) * time.Second)
	defer ticker.Stop()
	elapsed := 0
	for {
		select {
		case got := <-ch:
			if got.err != nil {
				got.res.Code = 127
			}
			return got.res
		case <-ticker.C:
			elapsed += step
			fmt.Fprintf(o.errOut(), "devzone : … still running (%d s)\n", elapsed)
		}
	}
}

// lastNpmLog returns the newest npm journal, or its folder when none exists.
func lastNpmLog(home string) string {
	pattern := filepath.Join(home, ".npm", "_logs", "*-debug-0.log")
	matches, err := filepath.Glob(pattern)
	if err == nil && len(matches) > 0 {
		return matches[len(matches)-1]
	}
	return filepath.Join(home, ".npm", "_logs")
}

// installAssistants installs each pinned package with three attempts and
// returns the packages that could not be installed.
func installAssistants(ctx context.Context, o Options) []string {
	packages, _ := o.assistants()
	var failed []string
	for _, pkg := range packages {
		binary := binaryOf(pkg)
		ok := false
		for attempt := 1; attempt <= 3; attempt++ {
			install := runWithProgress(ctx, o, "npm", []string{
				"install", "-g", "--no-fund", "--no-audit", "--loglevel=error", pkg,
			})
			version, err := o.runner().Run(ctx, binary, []string{"--version"}, dzexec.Opts{})
			if install.Code == 0 && err == nil && version.Code == 0 {
				ok = true
				break
			}
			if attempt < 3 {
				fmt.Fprintf(o.errOut(), "devzone : installation of %s incomplete, retrying (%d/3)…\n", pkg, attempt+1)
			}
		}
		if !ok {
			failed = append(failed, pkg)
		}
	}
	return failed
}

// uninstallAssistants removes the two assistants by their package names.
func uninstallAssistants(ctx context.Context, o Options) {
	_, names := o.assistants()
	clean := make([]string, 0, len(names))
	for _, name := range names {
		if i := lastAt(name); i >= 0 {
			name = name[:i]
		}
		clean = append(clean, name)
	}
	o.runner().Run(ctx, "npm", append([]string{"uninstall", "-g"}, clean...), dzexec.Opts{})
}

// lastAt returns the index of the last @ of a pinned package name.
func lastAt(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '@' {
			return i
		}
	}
	return -1
}
