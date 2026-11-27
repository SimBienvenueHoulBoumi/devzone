package workspace

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// WaitForPod waits for the StatefulSet revision of the workspace pod and for a
// Running phase, as the former shell wait did. The reason of a failed image
// pull is told to the user, and the workspace is undeployed so that selfHeal
// cannot recreate a bad pod. A pod that is still starting when the timeout
// expires is only reported, never an error.
func WaitForPod(r Runner, image string, out, errOut io.Writer, undeploy func() int) int {
	env := waitEnv{
		runner: r, out: out, errOut: errOut, undeploy: undeploy,
		timeout: waitSeconds("DEVZONE_WORKSPACE_WAIT", 120),
		step:    waitSeconds("DEVZONE_WORKSPACE_STEP", 2),
		sleep:   time.Sleep,
		start:   time.Now,
	}
	return env.wait(image)
}

// waitEnv holds what one wait touches, injected so that a test needs no real
// clock, no sleep and no cluster: only the fake Runner and a fake undeploy.
type waitEnv struct {
	runner   Runner
	timeout  time.Duration
	step     time.Duration
	sleep    func(time.Duration)
	start    func() time.Time
	undeploy func() int
	out      io.Writer
	errOut   io.Writer
}

// waitSeconds reads a whole number of seconds from the environment, with the
// shell default when the value is missing or not a number.
func waitSeconds(key string, fallback int) time.Duration {
	value, err := strconv.Atoi(os.Getenv(key))
	if err != nil || value < 0 {
		value = fallback
	}
	return time.Duration(value) * time.Second
}

// kubectlValue runs one read-only kubectl query and returns its standard
// output, ignoring a failure as the shell does with "|| true".
func (e waitEnv) kubectlValue(args ...string) string {
	var out strings.Builder
	_, _ = e.runner.Kubectl(append(contextFlag(e.runner), args...), nil, &out, io.Discard)
	return out.String()
}

// wait is the loop of wait_for_pod. Only the revision the StatefulSet is
// updating to is judged: right after a helm upgrade the pod is still the old
// one, and judging it would declare success too early.
func (e waitEnv) wait(image string) int {
	begin := e.start()
	for e.start().Sub(begin) < e.timeout {
		target := e.kubectlValue("get", "statefulset", "devzone-workspace", "--namespace", namespace,
			"-o", `jsonpath={.status.updateRevision}`)
		pod := e.kubectlValue("get", "pod", "devzone-workspace-0", "--namespace", namespace,
			"-o", `jsonpath={.metadata.labels.controller-revision-hash}`)
		if target == "" || pod == "" || target != pod {
			e.sleep(e.step)
			continue
		}
		state := e.kubectlValue("get", "pod", "devzone-workspace-0", "--namespace", namespace,
			"-o", `jsonpath={.status.phase} {.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}`)
		if strings.Contains(state, "ErrImagePull") || strings.Contains(state, "ImagePullBackOff") {
			e.imageFailure(image)
			_ = e.undeploy()
			return 1
		}
		if strings.HasPrefix(state, "Running") {
			fmt.Fprintf(e.out, "✔ workspace started (%s)\n", image)
			return 0
		}
		e.sleep(e.step)
	}
	fmt.Fprintf(e.errOut, "⚠ pod not ready after %d s: devzone workspace status\n", int(e.timeout/time.Second))
	return 0
}

// imageFailure writes the reason of a pull failure, with the architecture when
// the image has no build for it, and the hint for a manually built image.
func (e waitEnv) imageFailure(image string) {
	events := e.kubectlValue("get", "events", "--namespace", namespace,
		"--field-selector", "involvedObject.name=devzone-workspace-0",
		"-o", `jsonpath={.items[*].message}`)
	if strings.Contains(events, "no match for platform") {
		arch := e.kubectlValue("get", "nodes", "-o", `jsonpath={.items[0].status.nodeInfo.architecture}`)
		fmt.Fprintf(e.errOut, "✖ image %s has no build for %s: devzone releases publish it for amd64 and arm64.\n", image, arch)
	} else {
		fmt.Fprintf(e.errOut, "✖ image %s not found: it is published at each devzone release.\n", image)
	}
	fmt.Fprintln(e.errOut, "  For a manually built image: devzone workspace start --image <repository:tag>")
}
