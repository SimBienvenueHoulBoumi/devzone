package workspace

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// UpdateEnv holds what a workspace update touches. Git, the registry, the
// confirmation and the deploy are injected so that a test uses no network, no
// git repository and no terminal.
type UpdateEnv struct {
	Runner      Runner
	Out         io.Writer
	ErrOut      io.Writer
	Tags        func(repository string) []string
	ImageExists func(tag string) bool
	Confirm     func(question string) bool
	Terminal    func() bool
	Deploy      func(repository, tag, revision string) int
	Reconcile   func() int
	Ready       func() (string, bool)
	Modules     string
}

// Run parses the options, resolves the release, asks for confirmation and
// deploys at the release, as update_workspace in workspace-update.sh.
func (e UpdateEnv) Run(args []string) int {
	version, yes, errOut, ok := parseUpdateOptions(args)
	if !ok {
		fmt.Fprint(e.ErrOut, errOut)
		return 1
	}
	if reason, ready := e.ready(); !ready {
		fmt.Fprintln(e.ErrOut, reason)
		return 1
	}
	if version == "" {
		if e.Tags == nil {
			fmt.Fprintf(e.ErrOut, "✖ no stable release found in %s (network, or no vX.Y.Z tag): nothing changed\n", imageRepository)
			return 1
		}
		version = LatestVersion(e.Tags(imageRepository))
		if version == "" {
			fmt.Fprintf(e.ErrOut, "✖ no stable release found in %s (network, or no vX.Y.Z tag): nothing changed\n", imageRepository)
			return 1
		}
	} else if !validRelease(version) {
		fmt.Fprintf(e.ErrOut, "✖ option --version: expected X.Y.Z, got: %s\n", version)
		return 1
	}
	if e.ImageExists == nil || !e.ImageExists(version) {
		fmt.Fprintf(e.ErrOut, "✖ image %s:%s not found on ghcr.io (the release may still be publishing, or the network is down): nothing changed\n", imageRepo(), version)
		return 1
	}
	if upToDate(e.Runner, version) {
		fmt.Fprintf(e.Out, "✔ already up to date: v%s\n", version)
		return 0
	}
	fmt.Fprintln(e.ErrOut, "⚠ the workspace pod will be recreated: the VS Code windows attached to it will disconnect")
	if !yes {
		terminal := e.Terminal
		if terminal == nil {
			terminal = stdinIsTerminal
		}
		if !terminal() {
			fmt.Fprintln(e.ErrOut, "✖ no terminal to confirm: run again with --yes (devzone workspace update --yes)")
			return 1
		}
		question := fmt.Sprintf("Update the workspace to v%s? [y/N] ", version)
		confirm := e.Confirm
		if confirm == nil {
			confirm = terminalConfirm
		}
		if !confirm(question) {
			fmt.Fprintln(e.ErrOut, "✖ canceled, nothing changed")
			return 1
		}
	}
	revision := "v" + version
	if e.Deploy == nil {
		return 1
	}
	if status := e.Deploy(imageRepo(), version, revision); status != 0 {
		return status
	}
	if argocdActive(e.Runner, e.Modules) && e.Reconcile != nil {
		if status := e.Reconcile(); status != 0 {
			return status
		}
	}
	fmt.Fprintf(e.Out, "✔ workspace on v%s; follow the rollout: devzone workspace status\n", version)
	return 0
}

// ready reports the cluster state with the injected check, or with KubeReady.
func (e UpdateEnv) ready() (string, bool) {
	if e.Ready != nil {
		return e.Ready()
	}
	return KubeReady(e.Runner, true)
}

// stdinIsTerminal tells whether a user can answer the confirmation prompt.
func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// terminalConfirm asks the question and accepts y, Y or yes, as the read of
// update_workspace does. It is only called when stdin is a terminal.
func terminalConfirm(question string) bool {
	fmt.Print(question)
	answer, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	}
	return false
}
