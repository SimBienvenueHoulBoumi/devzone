package podcmd

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// devcontainerDirOverride is the single test hook for the installed devzone
// folder: it replaces the image path when reading versions.env.
const devcontainerDirOverride = "DEVZONE_DEVCONTAINER_DIR"

// devcontainerDir returns the installed .devcontainer folder holding
// versions.env; the override keeps tests independent from the image paths.
func devcontainerDir() string {
	if dir := os.Getenv(devcontainerDirOverride); dir != "" {
		return dir
	}
	return filepath.Join("/usr/local/share/devzone", ".devcontainer")
}

// initRepowarden checks the pinned repowarden version, installs it when it
// differs and reinstalls the global hooks; a missing versions file is a no-op.
func initRepowarden(ctx *cli.Context) bool {
	path := filepath.Join(devcontainerDir(), "versions.env")
	pinned, ok := readRepowardenVersion(path)
	if !ok {
		logInit(ctx, fmt.Sprintf("repowarden: %s missing", path))
		return true
	}
	current, _ := ctx.Runner.Run(context.Background(), "repowarden",
		[]string{"--version"}, exec.Opts{})
	installed := strings.TrimSpace(string(current.Stdout))
	ok = true
	if current.Code == 0 && installed == pinned {
		logInit(ctx, "repowarden "+installed+" already installed")
	} else {
		res, err := ctx.Runner.Run(context.Background(), "npm",
			[]string{"install", "-g", "repowarden@" + pinned}, exec.Opts{})
		writeRunOutput(ctx, res)
		if err != nil || res.Code != 0 {
			logInit(ctx, "repowarden: npm install failed")
			ok = false
		} else {
			logInit(ctx, "repowarden "+pinned+" installed")
		}
	}
	res, err := ctx.Runner.Run(context.Background(), "repowarden",
		[]string{"install", "--global", "--lang", "fr"}, exec.Opts{})
	writeRunOutput(ctx, res)
	if err != nil || res.Code != 0 {
		logInit(ctx, "repowarden: install --global failed")
		return false
	}
	logInit(ctx, "repowarden global hooks installed")
	return ok
}

// readRepowardenVersion reads REPOWARDEN_VERSION from a versions file without
// executing it, returning false when the file or the key is absent.
func readRepowardenVersion(path string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found || strings.TrimSpace(key) != "REPOWARDEN_VERSION" {
			continue
		}
		if version := strings.Trim(strings.TrimSpace(value), "\"'"); version != "" {
			return version, true
		}
	}
	return "", false
}
