package relays

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Env carries the collaborators of a port command. Tests replace the runner
// and the probe, so neither a cluster nor the network is needed.
type Env struct {
	State    string
	Instance string
	Runner   fexec.Runner
	Probe    func(int) bool
	Out      io.Writer
	Err      io.Writer
}

// New wires a relays environment to the real kubectl runner and HTTP probe.
func New(stateFile, instance string, out, errOut io.Writer) *Env {
	return &Env{
		State: stateFile, Instance: instance, Runner: fexec.ExecRunner{},
		Probe: Responds, Out: out, Err: errOut,
	}
}

// selector returns the label selector of the relays of this instance and port.
func (e *Env) selector(n int) string {
	return "devzone.instance=" + e.Instance + ",devzone.port=" + strconv.Itoa(n)
}

// Active reports whether a relay pod exists for the port, using kubectl
// instead of a local process. A missing cluster means no active relay.
func (e *Env) Active(n int) bool {
	if e.Runner == nil {
		return false
	}
	res, err := e.Runner.Run(context.Background(), "kubectl", []string{
		"get", "pods", "--all-namespaces", "-l", e.selector(n), "-o", "name",
	}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	return strings.Contains(string(res.Stdout), "pod/"+RelayName(e.Instance, n))
}

// Close removes the relay pod and then the port from the state. A failure to
// remove the pod is ignored like the shell, but a state failure is returned.
func (e *Env) Close(n int) error {
	if e.Runner != nil {
		_, _ = e.Runner.Run(context.Background(), "kubectl", []string{
			"delete", "pod", "--all-namespaces", "-l", e.selector(n), "--ignore-not-found",
		}, fexec.Opts{})
	}
	if err := RemovePort(e.State, n); err != nil {
		return err
	}
	fmt.Fprintf(e.Out, "✔ relay closed: %d\n", n)
	return nil
}

// Responds reports whether an application answers on the workstation port,
// with the same two-second ceiling as the former curl call.
func Responds(n int) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get("http://127.0.0.1:" + strconv.Itoa(n))
	if err != nil {
		return false
	}
	_ = response.Body.Close()
	return true
}

// responds reports the injected application probe, defaulting to no answer.
func (e *Env) responds(n int) bool {
	if e.Probe == nil {
		return false
	}
	return e.Probe(n)
}
