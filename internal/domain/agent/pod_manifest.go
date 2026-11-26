package agent

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	podRootRe   = regexp.MustCompile(`^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$`)
	podPathRe   = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
	podLabelRe  = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$`)
	podTicketRe = regexp.MustCompile(`^dz-[0-9]+$`)
	podDigitsRe = regexp.MustCompile(`^[0-9]+$`)
)

// AgentPodRoot projects root, read by launcher only (no trailing slash).
func AgentPodRoot() string {
	return envStr("DEVZONE_ROOT", "/workspaces/projets")
}

// AgentPodModulesFile module state file on workspace volume.
func AgentPodModulesFile() string {
	return envStr("DEVZONE_AGENT_POD_MODULES_FILE", filepath.Join(AgentPodRoot(), ".devzone.modules"))
}

// AgentPodActiveDeadlineSeconds default 1800.
func AgentPodActiveDeadlineSeconds() string {
	return envStr("DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS", "1800")
}

// AgentPodCPULimit default 2.
func AgentPodCPULimit() string { return envStr("DEVZONE_AGENT_POD_CPU_LIMIT", "2") }

// AgentPodMemLimit default 4Gi.
func AgentPodMemLimit() string { return envStr("DEVZONE_AGENT_POD_MEM_LIMIT", "4Gi") }

// AgentPodTimeout default activeDeadlineSeconds + 120.
func AgentPodTimeout() string {
	if v := os.Getenv("DEVZONE_AGENT_POD_TIMEOUT"); v != "" {
		return v
	}
	ad, _ := atoi(AgentPodActiveDeadlineSeconds())
	return itoa(ad + 120)
}

// PodState filled by AgentPodValidateFolder.
type PodState struct {
	WorktreeSubpath   string
	WorktreeMountpath string
	GitSubpath        string
	GitMountpath      string
	SessionLabel      string
	Ticket            string
}

// AgentPodPathOK checks under root, only [A-Za-z0-9._/-], no . or .. part.
func AgentPodPathOK(root, path string) bool {
	if !podRootRe.MatchString(root) {
		return false
	}
	if !strings.HasPrefix(path, root+"/") {
		return false
	}
	if !podPathRe.MatchString(path) {
		return false
	}
	withSlash := path + "/"
	if strings.Contains(withSlash, "/./") || strings.Contains(withSlash, "/../") || strings.Contains(withSlash, "//") {
		return false
	}
	return true
}

// AgentPodValidateFolder validates a worktree folder under root; fills state.
func AgentPodValidateFolder(folder, root string, stderr func(string)) (PodState, bool) {
	var st PodState
	fail := func(msg string) (PodState, bool) {
		if stderr != nil {
			stderr(msg)
		}
		return st, false
	}
	if folder == "" {
		return fail("devzone agent --pod : folder missing")
	}
	if !strings.HasPrefix(folder, root+"/") {
		return fail("devzone agent --pod : folder outside the projects root " + root + " : " + folder)
	}
	if !AgentPodPathOK(root, folder) {
		return fail("devzone agent --pod : invalid folder path : " + folder)
	}
	gitfile := filepath.Join(folder, ".git")
	info, err := os.Stat(gitfile)
	if err != nil || info.IsDir() {
		return fail("devzone agent --pod : no .git file (not a git worktree) : " + folder)
	}
	gitdir := ""
	for _, line := range strings.Split(readFileString(gitfile), "\n") {
		if strings.HasPrefix(line, "gitdir:") {
			gitdir = strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
			break
		}
	}
	if gitdir == "" {
		return fail("devzone agent --pod : .git without gitdir line : " + folder)
	}
	common := ""
	if idx := strings.LastIndex(gitdir, "/worktrees/"); idx >= 0 {
		common = gitdir[:idx]
	} else {
		return fail("devzone agent --pod : gitdir is not a worktree : " + gitdir)
	}
	if !strings.HasPrefix(common, root+"/") {
		return fail("devzone agent --pod : worktree depot outside the projects root " + root + " : " + common)
	}
	if !AgentPodPathOK(root, common) {
		return fail("devzone agent --pod : invalid depot path : " + common)
	}
	base := filepath.Base(folder)
	if !podLabelRe.MatchString(base) {
		return fail("devzone agent --pod : invalid label value : " + base)
	}
	if len(base) > 63 {
		return fail("devzone agent --pod : label value too long : " + base)
	}
	st.WorktreeMountpath = folder
	st.WorktreeSubpath = strings.TrimPrefix(folder, root+"/")
	st.GitMountpath = common
	st.GitSubpath = strings.TrimPrefix(common, root+"/")
	st.SessionLabel = base
	if podTicketRe.MatchString(base) {
		st.Ticket = strings.TrimPrefix(base, "dz-")
		if !podDigitsRe.MatchString(st.Ticket) {
			st.Ticket = ""
		}
	}
	return st, true
}
