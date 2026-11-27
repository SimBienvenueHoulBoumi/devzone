// Package create holds the Go port of devzone-create.sh (#884): creation of a
// devzone folder. The package files are copied, .argocd.conf and
// .devzone.version are written, and the workspace is started in the cluster.
// Every external command goes through a Runner, so tests stay hermetic.
package create

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/createmode"
)

// PackageItems are the entries of the package copied into a new devzone: the
// « files » of package.json, without bin/, manage/ and charts/ (manage/scripts is
// copied apart).
var PackageItems = []string{".devcontainer", "Makefile", ".gitattributes", "README.md", "LICENSE"}

// GitignoreLines are always present in the .gitignore of a devzone, added to,
// never overwritten.
var GitignoreLines = []string{
	"# Each workspace project has its own git repository",
	"workspace/*",
	"!workspace/.gitkeep",
	".DS_Store",
	".devzone.log",
	".devzone.state",
	".password",
	".devzone.backup/",
}

// Options carries the parsed arguments and injected inputs of one creation.
type Options struct {
	Target     string
	Gitops     string
	Kubernetes bool
	Package    string
	Version    string
	In         io.Reader
	Out        io.Writer
	Err        io.Writer
	Runner     fexec.Runner
	LookPath   func(string) (string, error)
	Terminal   bool
	StdinTTY   bool
	Ctx        context.Context
}

// unknownOption is the refusal of an unknown creation option, as the script does.
const unknownOptionFormat = "✖ unknown option: %s (devzone <folder> [--gitops github|none|<url>] [--kubernetes])"

// ParseArgs splits the arguments after the folder name, as create_workstation
// does: --gitops <value> or --gitops=<value>, --kubernetes, anything else is
// refused; a trailing --gitops without a value is refused.
func ParseArgs(args []string) (gitops string, kubernetes bool, err error) {
	expect := false
	for _, arg := range args {
		if expect {
			gitops = arg
			expect = false
			continue
		}
		switch {
		case arg == "--gitops":
			expect = true
		case strings.HasPrefix(arg, "--gitops="):
			gitops = strings.TrimPrefix(arg, "--gitops=")
		case arg == "--kubernetes":
			kubernetes = true
		default:
			return "", false, fmt.Errorf(unknownOptionFormat, arg)
		}
	}
	if expect {
		return "", false, fmt.Errorf("✖ --gitops expects a value (github, none or a URL)")
	}
	return gitops, kubernetes, nil
}

// Create makes a devzone in Target: refuses a non-empty target, picks the
// creation mode, asks for the GitOps repository when none is named and no
// terminal rules apply, copies the package, writes .argocd.conf and
// .devzone.version, then starts the workspace. A failed start keeps the folder.
func Create(opts Options) error {
	if opts.Out == nil {
		opts.Out = io.Discard
	}
	if opts.Err == nil {
		opts.Err = io.Discard
	}
	if opts.In == nil {
		opts.In = strings.NewReader("")
	}
	if opts.Runner == nil {
		opts.Runner = fexec.ExecRunner{}
	}
	if opts.LookPath == nil {
		opts.LookPath = exec.LookPath
	}
	if opts.Ctx == nil {
		opts.Ctx = context.Background()
	}

	target := opts.Target
	if nonEmpty(target) {
		return fmt.Errorf("✖ %s exists and is not empty: nothing is overwritten. Choose another folder.", target)
	}

	option := ""
	if opts.Kubernetes {
		option = "kubernetes"
	}
	// Mode before any copy: --kubernetes without a cluster creates nothing (#497).
	// The notices of the choice go to stdout, as the shell script printed them.
	session := &createmode.Session{
		Ctx:      opts.Ctx,
		Runner:   opts.Runner,
		LookPath: opts.LookPath,
		In:       opts.In,
		Out:      opts.Out,
		Err:      opts.Err,
		Terminal: option == "" && opts.Terminal,
	}
	mode, ok := session.Choose(option)
	if !ok {
		return ErrSilent
	}

	gitops := opts.Gitops
	if gitops == "" && opts.StdinTTY {
		gitops = askGitops(opts.In, opts.Err, opts.Runner, opts.Ctx)
	}
	// Without a terminal, or with an empty answer (no default), no repository is
	// named: none, never an empty repo written to .argocd.conf
	if gitops == "" {
		fmt.Fprintln(opts.Err, "⚠ no GitOps repository for Argo CD: pass --gitops <github|none|https://github.com/<login>/<name>.git> to create a devzone without a terminal; using none")
		gitops = "none"
	}

	if err := os.MkdirAll(filepath.Join(target, "workspace"), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(target, "manage"), 0o755); err != nil {
		return err
	}
	if err := copyPackage(opts.Package, target); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(target, "workspace", ".gitkeep"), nil, 0o644); err != nil {
		return err
	}
	gitignore := filepath.Join(target, ".gitignore")
	if err := os.WriteFile(gitignore, nil, 0o644); err != nil {
		return err
	}
	if err := completeGitignore(target); err != nil {
		return err
	}
	// `chmod +x`: add execute to whatever permissions the copy has
	uninstall := filepath.Join(target, "manage", "scripts", "uninstall.sh")
	info, err := os.Stat(uninstall)
	if err != nil {
		return err
	}
	if err := os.Chmod(uninstall, info.Mode().Perm()|0o111); err != nil {
		return err
	}
	if err := createmode.Write(target, mode); err != nil {
		return fmt.Errorf("✖ cannot write the workspace mode: %w", err)
	}

	value := gitopsValue(gitops, opts)
	confPath := filepath.Join(target, ".argocd.conf")
	if err := confSet(confPath, "argocd", "repo", value); err != nil {
		return err
	}
	if value == "none" {
		fmt.Fprintln(opts.Out, "✔ no GitOps repository: the Applications are applied directly (devzone workspace argocd init to change)")
	} else {
		fmt.Fprintf(opts.Out, "✔ GitOps repository: %s (%s)\n", value, confPath)
	}

	absolute, err := filepath.Abs(target)
	if err != nil {
		return err
	}
	// `cd target && pwd` resolves symbolic links; abs alone would not
	if resolved, err := filepath.EvalSymlinks(absolute); err == nil {
		absolute = resolved
	}
	if err := writeManifest(opts.Package, absolute, opts.Version); err != nil {
		return err
	}
	fmt.Fprintf(opts.Out, "✔ devzone %s created in %s\n", opts.Version, absolute)
	// The workspace goes to the cluster (kube check done by the choice above)
	script := filepath.Join(opts.Package, "manage", "workspace.sh")
	start := &createmode.Session{
		Ctx:      opts.Ctx,
		Runner:   opts.Runner,
		LookPath: opts.LookPath,
		In:       opts.In,
		Out:      opts.Out,
		Err:      opts.Err,
	}
	if err := start.Start(absolute, script); err != nil {
		return ErrSilent
	}
	return nil
}

// ErrSilent marks a failure already reported on stderr, so the caller exits 1
// without printing anything more.
var ErrSilent = errors.New("silent failure")

// nonEmpty tells whether a path exists and is not an empty directory.
func nonEmpty(path string) bool {
	entries, err := os.ReadDir(path)
	if err != nil {
		if info, statErr := os.Stat(path); statErr == nil && !info.IsDir() {
			return true
		}
		return false
	}
	return len(entries) > 0
}
