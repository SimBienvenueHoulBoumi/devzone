package command

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	fwexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// failureText explains a failed command: its stderr when it wrote one, else the
// start error or the exit status.
func failureText(res fwexec.Result, err error) string {
	if msg := strings.TrimSpace(string(res.Stderr)); msg != "" {
		return msg
	}
	if err != nil {
		return err.Error()
	}
	return "failed"
}

// removeEach runs one removal per id with the arguments args builds. A success
// prints "✔ <label> removed: <id>"; a failure is reported on errOut. It returns 1
// when at least one removal failed, and goes on with the others.
func removeEach(d engineCall, ids []string, label string, args func(id string) []string, out, errOut io.Writer) int {
	status := 0
	for _, id := range ids {
		res, err := d.run(args(id)...)
		if err != nil {
			fmt.Fprintf(errOut, "✖ %s %s: %s\n", label, id, failureText(res, err))
			status = 1
			continue
		}
		fmt.Fprintf(out, "✔ %s removed: %s\n", label, id)
	}
	return status
}

// forceRemove is the arguments of "<engine> rm -f <id>".
func forceRemove(id string) []string { return []string{"rm", "-f", id} }

// removeHostFirst removes what the folder created on the host: its containers,
// then their images, then the former internal and devcontainer volumes.
// It returns 1 when one removal failed.
func removeHostFirst(d engineCall, h hostPlan, out, errOut io.Writer) int {
	status := removeEach(d, h.containers, "container", forceRemove, out, errOut)
	status = max(status, removeEach(d, h.images, "image", func(id string) []string {
		return []string{"rmi", id}
	}, out, errOut))
	volumes := append(append([]string{}, h.dind...), h.volumes...)
	return max(status, removeEach(d, volumes, "volume", func(name string) []string {
		return []string{"volume", "rm", name}
	}, out, errOut))
}

// removeHostLast removes the kind clusters of the instance, then the kind network
// when no container uses it any more, then the labeled containers of the instance.
// It returns 1 when one removal failed.
func removeHostLast(d engineCall, h hostPlan, out, errOut io.Writer) int {
	status := removeEach(d, h.kindClusters, "kind cluster container", forceRemove, out, errOut)
	if !h.inside {
		status = max(status, removeKindNetwork(d, out, errOut))
	}
	return max(status, removeEach(d, h.labeled, "labeled container", forceRemove, out, errOut))
}

// removeKindNetwork removes the kind network when its inspection shows no
// container on it. A network in use, or one that does not exist, is left alone.
func removeKindNetwork(d engineCall, out, errOut io.Writer) int {
	res, err := d.run("network", "inspect", "kind")
	if err != nil || !networkEmpty(res.Stdout) {
		return 0
	}
	if res, err := d.run("network", "rm", "kind"); err != nil {
		fmt.Fprintf(errOut, "✖ kind network: %s\n", failureText(res, err))
		return 1
	}
	fmt.Fprintln(out, "✔ kind network removed")
	return 0
}

// networkEmpty reports whether a "<engine> network inspect" document lists no
// container: every network in it has an empty Containers map.
func networkEmpty(data []byte) bool {
	var nets []struct {
		Containers map[string]json.RawMessage `json:"Containers"`
	}
	if json.Unmarshal(data, &nets) != nil || len(nets) == 0 {
		return false
	}
	for _, n := range nets {
		if len(n.Containers) > 0 {
			return false
		}
	}
	return true
}
