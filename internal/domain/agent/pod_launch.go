package agent

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

// podTermSignal is SIGTERM expressed portably: syscall.Signal exists on Windows too.
const podTermSignal = syscall.Signal(15)

// AgentPodLaunch launches session in ephemeral pod (devzone agent --pod).
// It installs the INT/TERM handlers, then delegates to agentPodLaunch so tests
// can inject signals without sending a real one to the test process.
func AgentPodLaunch(ctx context.Context, r Runner, clock Clock, folderRaw, consigneRaw, state string, errOut io.Writer) int {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, podTermSignal)
	defer signal.Stop(sigCh)
	return agentPodLaunch(ctx, r, clock, folderRaw, consigneRaw, state, errOut, sigCh)
}

// agentPodLaunch runs the pod session and returns 130 on INT, 143 on TERM, with
// the pod and its ConfigMap always deleted (shell EXIT/INT/TERM trap).
func agentPodLaunch(ctx context.Context, r Runner, clock Clock, folderRaw, consigneRaw, state string, errOut io.Writer, sigCh <-chan os.Signal) int {
	if os.Getenv("DEVZONE_WORKSPACE") != "kubernetes" {
		fmt.Fprintln(errOut, "devzone agent --pod : must be called from the workspace pod (DEVZONE_WORKSPACE=kubernetes)")
		return 1
	}
	root := AgentPodRoot()
	if !AgentPodPathOK(root, folderRaw) {
		fmt.Fprintln(errOut, "devzone agent --pod : invalid folder path : "+folderRaw)
		return 1
	}
	if !dirExists(folderRaw) {
		fmt.Fprintln(errOut, "devzone agent --pod : folder not found : "+folderRaw)
		return 1
	}
	folder := realPath(folderRaw)
	if !fileExists(consigneRaw) {
		fmt.Fprintln(errOut, "devzone agent --pod : brief not found : "+consigneRaw)
		return 1
	}
	consigne := realPath(consigneRaw)
	st, ok := AgentPodValidateFolder(folder, root, func(m string) { fmt.Fprintln(errOut, m) })
	if !ok {
		return 1
	}
	modulesFile := AgentPodModulesFile()
	if !fileExists(modulesFile) {
		fmt.Fprintln(errOut, "devzone agent --pod : modules file missing : "+modulesFile+" (run devzone enable ai on the workspace)")
		return 1
	}
	if state == "" {
		state = envStr("AGENT_STATE", envStr("DEVZONE_AGENT_STATE", homeLocalState()))
	}
	os.MkdirAll(state, 0o755)
	journalFile := filepath.Join(state, st.SessionLabel+".pod.log")
	os.WriteFile(journalFile, nil, 0o644)
	podName := AgentPodName(folder)
	cleaner := &podCleaner{ctx: ctx, r: r, name: podName, journal: journalFile}
	defer cleaner.cleanup()
	if r != nil {
		res, _ := r.Run(ctx, "kubectl", []string{"create", "configmap", AgentPodConfigMapName(podName), "--from-file=consigne.md=" + consigne}, Opts{})
		if res.Code != 0 {
			fmt.Fprintln(errOut, "devzone agent --pod : unable to create the configmap")
			return 1
		}
	}
	manifestFile, err := BuildManifest(ctx, r, folder, podName, st)
	if err != nil {
		fmt.Fprintln(errOut, "devzone agent --pod : unable to build the manifest")
		return 1
	}
	cleaner.manifest = manifestFile
	if r != nil {
		res, _ := r.Run(ctx, "kubectl", []string{"create", "-f", manifestFile}, Opts{})
		if res.Code != 0 {
			fmt.Fprintln(errOut, "devzone agent --pod : unable to create the pod (kubectl create -f)")
			fmt.Fprintln(errOut, "devzone agent --pod : try again without --pod")
			return 1
		}
	}
	maxWait, _ := atoi(AgentPodTimeout())
	waitDone := make(chan PodWaitResult, 1)
	go func() { waitDone <- AgentPodWait(ctx, r, podName, clock, maxWait) }()
	var waitRes PodWaitResult
	select {
	case sig := <-sigCh:
		cleaner.cleanup()
		if sig == podTermSignal {
			return 143
		}
		return 130
	case waitRes = <-waitDone:
	}
	rc := 0
	if !waitRes.OK {
		rc = 1
	}
	AgentPodFetchLogs(ctx, r, podName, journalFile)
	appendLine(journalFile, "=== end of agent session in pod (phase: "+waitRes.Phase+")")
	if rc != 0 || waitRes.Phase == "Failed" {
		AgentPodInitFailure(ctx, r, podName, errOut)
	}
	AgentPodShowTail(journalFile, errOut)
	if rc != 0 {
		fmt.Fprintf(errOut, "devzone agent --pod : pod did not finish in time (phase: %s) ; log : %s\n", waitRes.Phase, journalFile)
		return 1
	}
	if waitRes.Phase == "Failed" {
		fmt.Fprintf(errOut, "devzone agent --pod : session ended in failure ; log : %s\n", journalFile)
		return 1
	}
	fmt.Fprintf(errOut, "devzone agent --pod : session ended (phase: %s) ; log : %s\n", waitRes.Phase, journalFile)
	return 0
}

func homeLocalState() string {
	home := os.Getenv("HOME")
	if home == "" {
		home = "."
	}
	return filepath.Join(home, ".local", "state", "oc-lancer")
}

func realPath(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		if resolved, err := filepath.EvalSymlinks(abs); err == nil {
			return resolved
		}
		return abs
	}
	return p
}
