package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
)

// RightsFiles are protected rights files, relative to project root. Fixed list,
// no environment changes it, agent cannot add; agent-rights.sh is in it,
// otherwise an agent could empty the list. Identical to the shell RIGHTS_FILES.
var RightsFiles = []string{
	".devcontainer/opencode/agent.json",
	".devcontainer/opencode.jsonc",
	".repowarden.conf",
	".devcontainer/agent-rights.sh",
}

// RightsDir is snapshot dir of a project's rights files in agent state.
func RightsDir(stateDir, folder string) string {
	return filepath.Join(stateDir, "droits-"+filepath.Base(folder))
}

// RightsSnapshot copies each rights file (or notes absence) + starting HEAD,
// clears previous alert on this project. Shell rights_snapshot; git via Runner.
func RightsSnapshot(ctx context.Context, r Runner, stateDir, folder string) error {
	d := RightsDir(stateDir, folder)
	os.RemoveAll(d)
	os.RemoveAll(d + ".alerte")
	os.MkdirAll(filepath.Join(d, "fichiers"), 0o755)
	var absents strings.Builder
	for _, f := range RightsFiles {
		src := filepath.Join(folder, f)
		if fileExists(src) {
			dst := filepath.Join(d, "fichiers", f)
			os.MkdirAll(filepath.Dir(dst), 0o755)
			copyFilePreserve(src, dst)
		} else {
			absents.WriteString(f + "\n")
		}
	}
	os.WriteFile(filepath.Join(d, "absents"), []byte(absents.String()), 0o644)
	head := ""
	if r != nil {
		res, err := r.Run(ctx, "git", []string{"-C", folder, "rev-parse", "HEAD"}, Opts{})
		if err == nil && res.Code == 0 {
			head = strings.TrimSpace(string(res.Stdout))
		}
	}
	os.WriteFile(filepath.Join(d, "head"), []byte(head+"\n"), 0o644)
	return nil
}

// RightsRestore restores a rights file to its snapshot (removed when absent).
func RightsRestore(folder, f, snapshotDir string) error {
	d := snapshotDir
	if listContains(readFileString(filepath.Join(d, "absents")), f) {
		os.Remove(filepath.Join(folder, f))
		return nil
	}
	src := filepath.Join(d, "fichiers", f)
	dst := filepath.Join(folder, f)
	os.MkdirAll(filepath.Dir(dst), 0o755)
	return copyFilePreserve(src, dst)
}

// RightsVerify after each session: restores modified files, reports commits
// touching them in journal, raises alert; history never rewritten. rights_verify.
func RightsVerify(ctx context.Context, r Runner, stateDir, folder, journal string) {
	d := RightsDir(stateDir, folder)
	if !dirExists(d) {
		return
	}
	depart := strings.TrimSpace(readFileString(filepath.Join(d, "head")))
	for _, f := range RightsFiles {
		message := ""
		absent := listContains(readFileString(filepath.Join(d, "absents")), f)
		target := filepath.Join(folder, f)
		if absent {
			if fileExists(target) || dirExists(target) {
				message = "change reverted"
			}
		} else if !sameFile(filepath.Join(d, "fichiers", f), target) {
			message = "change reverted"
		}
		sha := ""
		if depart != "" && r != nil {
			res, err := r.Run(ctx, "git", []string{"-C", folder, "diff", "--name-only", depart, "HEAD", "--", f}, Opts{})
			if err == nil && strings.TrimSpace(string(res.Stdout)) != "" {
				res2, err2 := r.Run(ctx, "git", []string{"-C", folder, "log", "-1", "--format=%h", depart + "..HEAD", "--", f}, Opts{})
				if err2 == nil {
					sha = strings.TrimSpace(string(res2.Stdout))
				}
				if sha == "" {
					sha = "HEAD"
				}
				message = "change reverted in the tree, committed in " + sha + ": remove this commit before any push"
			}
		}
		if message == "" {
			continue
		}
		RightsRestore(folder, f, d)
		appendLine(journal, "=== ⚠ rights changed: "+f+" : "+message)
		appendLine(d+".alerte", f)
	}
}

// RightsAlerts lists projects whose rights were changed (devzone agent state).
func RightsAlerts(stateDir string) string {
	var out []string
	for _, f := range globDir(stateDir, "droits-*.alerte") {
		name := strings.TrimPrefix(base(f), "droits-")
		name = strings.TrimSuffix(name, ".alerte")
		out = append(out, "  ⚠ rights changed ("+name+"): see the journal\n")
	}
	return strings.Join(out, "")
}

func listContains(list, f string) bool {
	for _, line := range strings.Split(list, "\n") {
		if line == f {
			return true
		}
	}
	return false
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func sameFile(a, b string) bool {
	ba, err1 := os.ReadFile(a)
	bb, err2 := os.ReadFile(b)
	if err1 != nil || err2 != nil {
		return false
	}
	return string(ba) == string(bb)
}

// copyFilePreserve copies src to dst preserving mode (cp -p).
func copyFilePreserve(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	var mode os.FileMode = 0o644
	if info, err := os.Stat(src); err == nil {
		mode = info.Mode()
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		return err
	}
	return nil
}
