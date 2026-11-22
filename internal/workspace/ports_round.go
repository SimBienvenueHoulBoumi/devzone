package workspace

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

// roundEnv is everything one watcher round touches, injected so that tests run
// without a cluster: the Runner for the queries, the state folder, the modules
// file, the workstation port test, the way a relay process is started, the
// cap of application relays and the two output streams.
type roundEnv struct {
	runner  Runner
	dir     string
	modules string
	taken   func(int) bool
	start   func(*exec.Cmd) (int, error)
	max     int
	out     io.Writer
	errOut  io.Writer
}

// PortsRound runs one round of the port watcher (pw_round): it relays the
// ports that must be and are not yet, and removes the relays of ports that are
// gone. Lines about a relay go to out, warnings of the applications to errOut.
// The state folder is portsDir() and the status is always 0: a round never
// fails, the next one tries again. Nothing calls it yet: the watcher still runs
// in bash (#781).
func PortsRound(out, errOut io.Writer) int {
	env := roundEnv{
		runner: ExecRunner{}, dir: portsDir(), modules: modulesFile, taken: portTaken,
		start: startDetached, max: appsMax, out: out, errOut: errOut,
	}
	env.round()
	return 0
}

// round is pw_round. The wanted ports are, in this order and without repeating
// a port: the services of the active modules, the ports listening in the pod,
// and the applications of the cluster, which receive the ports already wanted
// so that they never take one. Each is relayed when it is not yet, then every
// relay or taken marker of a port that is no longer wanted is removed.
func (e roundEnv) round() {
	_ = os.MkdirAll(filepath.Join(e.dir, "relays"), 0o755)
	_ = os.MkdirAll(filepath.Join(e.dir, "taken"), 0o755)
	var wanted []int
	for _, svc := range watchedServices(e.runner, e.modules) {
		wanted = append(wanted, svc.local)
		e.relay(svc)
	}
	for _, port := range podPorts(e.runner) {
		if contains(wanted, port) {
			continue
		}
		wanted = append(wanted, port)
		e.relay(relayService{local: port, namespace: namespace, target: "pod/" + pod})
	}
	apps := appRound{runner: e.runner, dir: e.dir, modules: e.modules, taken: e.taken, max: e.max, errOut: e.errOut}
	for _, svc := range apps.run(wanted) {
		wanted = append(wanted, svc.local)
		e.relay(svc)
	}
	for _, sub := range []string{"relays", "taken"} {
		for _, name := range stateNames(filepath.Join(e.dir, sub)) {
			if port, ok := toPort(name); !ok || !contains(wanted, port) || strconv.Itoa(port) != name {
				removeRelay(e.dir, name)
			}
		}
	}
}

// relay starts the relay of one port unless one is alive (pw_relay): a live
// process in relays/<port> means nothing to do, so a round every few seconds
// costs nothing when all is well. A port already taken on the workstation is
// not relayed: the marker taken/<port> is created and the warning is printed
// once, not at every round, until the port is free again. Otherwise
// kubectl port-forward is started detached on 127.0.0.1, its pid written in
// relays/<port> and the marker removed.
func (e roundEnv) relay(svc relayService) {
	remote := svc.remote
	if remote == 0 {
		remote = svc.local
	}
	relayFile := filepath.Join(e.dir, "relays", strconv.Itoa(svc.local))
	if alive(readPid(relayFile)) {
		return
	}
	marker := filepath.Join(e.dir, "taken", strconv.Itoa(svc.local))
	if e.taken(svc.local) {
		if !present(marker) {
			touch(marker)
			fmt.Fprintf(e.out, "⚠ port %d already in use on the workstation, not relayed\n", svc.local)
		}
		return
	}
	args := append(watcherContext(e.runner), "--namespace", svc.namespace, "port-forward", "--address", "127.0.0.1",
		svc.target, fmt.Sprintf("%d:%d", svc.local, remote))
	pid, err := e.start(exec.Command("kubectl", args...))
	if err != nil {
		fmt.Fprintf(e.errOut, "⚠ port %d not relayed: %v\n", svc.local, err)
		return
	}
	_ = os.WriteFile(relayFile, []byte(strconv.Itoa(pid)+"\n"), 0o644)
	_ = os.Remove(marker)
	fmt.Fprintf(e.out, "→ port %d relayed on 127.0.0.1\n", svc.local)
}
