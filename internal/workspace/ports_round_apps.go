package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// appsMax is the number of application relays one round may start (PA_MAX in
// manage/scripts/workspace/ports-apps.sh): a cluster with hundreds of Services
// must not open hundreds of port-forward processes on the workstation.
const appsMax = 30

// appRound holds what one round of applications needs: the Runner for kubectl,
// the state folder, the modules file, the workstation port test and the cap
// (all injected, so tests need no cluster and no real port) and the two
// streams of the warnings.
type appRound struct {
	runner  Runner
	dir     string
	modules string
	taken   func(int) bool
	max     int
	errOut  io.Writer
}

// excludedPorts reads the ports the user keeps for themselves from the last
// line "excluded_ports=" of the modules file: the value after the first "=",
// commas read as spaces (grep, tail, cut and tr of pa_round). An entry counts
// only when written exactly as a port number (no leading zero), because the
// shell compares text; a missing file excludes nothing.
func excludedPorts(file string) []int {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	value := ""
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, "excluded_ports="); ok {
			value = rest
		}
	}
	var ports []int
	for _, item := range strings.Split(strings.ReplaceAll(value, ",", " "), " ") {
		if port, ok := toPort(item); ok && strconv.Itoa(port) == item {
			ports = append(ports, port)
		}
	}
	return ports
}

// appKey is the name of the state files of one Service port: the same
// "namespace.service.port" as the shell, which status reads back by its dots.
func appKey(ns, name string, port int) string {
	return ns + "." + name + "." + strconv.Itoa(port)
}

// contains tells whether port is in ports.
func contains(ports []int, port int) bool {
	for _, p := range ports {
		if p == port {
			return true
		}
	}
	return false
}

// touch creates an empty marker file, the way ": >file" does.
func touch(file string) {
	_ = os.WriteFile(file, nil, 0o644)
}

// present tells whether a state file or marker is there.
func present(file string) bool {
	_, err := os.Lstat(file)
	return err == nil
}

// readyOrAll reads the endpoint slices once for the round (pa_round). When they
// cannot be read every Service is relayed, which the user must hear about, but
// once: the marker endpoints-unreadable stays until a read succeeds again, so
// a cluster that stays unreadable does not repeat the warning every 3 seconds.
// ok is false when the readiness is unknown.
func (a appRound) readyOrAll() (ready map[string]bool, ok bool) {
	marker := filepath.Join(a.dir, "endpoints-unreadable")
	ready, err := readyServices(a.runner)
	if err == nil {
		_ = os.Remove(marker)
		return ready, true
	}
	if !present(marker) {
		touch(marker)
		fmt.Fprintln(a.errOut, "⚠ endpointslices unreadable, ready pods not checked")
	}
	return nil, false
}

// localPort gives the local port of a Service port: the one remembered in
// apps/<key> when it is a number nobody uses yet, so a Service keeps its URL
// from one round to the next, else a new one (newLocalPort). ok is false when
// none is free. The port is added to used and written back when it changed.
func (a appRound) localPort(key string, port int, used *[]int) (int, bool) {
	file := filepath.Join(a.dir, "apps", key)
	stored := readState(file)
	local, valid := toPort(stored)
	if !valid || contains(*used, local) {
		var err error
		if local, err = newLocalPort(port, *used, a.taken); err != nil {
			return 0, false
		}
	}
	*used = append(*used, local)
	if strconv.Itoa(local) != stored {
		_ = os.WriteFile(file, []byte(strconv.Itoa(local)), 0o644)
	}
	return local, true
}

// forget removes the state of the Services and ports that were not seen in this
// round: apps, cap and no-ready-pod markers of a Service that is gone.
func (a appRound) forget(seen map[string]bool) {
	for _, sub := range []string{"apps", "cap", "no-ready-pod"} {
		for _, name := range stateNames(filepath.Join(a.dir, sub)) {
			if !seen[name] {
				_ = os.Remove(filepath.Join(a.dir, sub, name))
			}
		}
	}
}

// run is one round of applications (pa_round), from the ports already wanted
// (the services of the modules and the pod). It returns the relays to run in
// the order of the cluster; for each Service port it keeps the local port in
// apps/, marks a Service without ready endpoint in no-ready-pod/ (neither
// relayed nor counted), stops at a.max relays and warns once per port past it
// (cap/), then forgets the Services that are gone.
func (a appRound) run(wanted []int) []relayService {
	for _, sub := range []string{"apps", "cap"} {
		_ = os.MkdirAll(filepath.Join(a.dir, sub), 0o755)
	}
	used := append(append([]int{}, wanted...), excludedPorts(a.modules)...)
	ready, readyKnown := a.readyOrAll()
	seen := map[string]bool{}
	var relays []relayService
	for _, svc := range discoverServices(a.runner) {
		if serviceExcluded(svc.namespace, svc.name, svc.clusterIP, svc.svcType, svc.annotation) {
			continue
		}
		for _, port := range svc.ports {
			key := appKey(svc.namespace, svc.name, port)
			seen[key] = true
			local, ok := a.localPort(key, port, &used)
			if !ok {
				fmt.Fprintf(a.errOut, "⚠ no free local port for %s/%s:%d\n", svc.namespace, svc.name, port)
				continue
			}
			noReady := filepath.Join(a.dir, "no-ready-pod", key)
			if readyKnown && !ready[svc.namespace+"/"+svc.name] {
				_ = os.MkdirAll(filepath.Dir(noReady), 0o755)
				touch(noReady)
				continue
			}
			_ = os.Remove(noReady)
			capFile := filepath.Join(a.dir, "cap", key)
			if len(relays) < a.max {
				_ = os.Remove(capFile)
				relays = append(relays, relayService{local: local, namespace: svc.namespace, target: "svc/" + svc.name, remote: port})
			} else if !present(capFile) {
				touch(capFile)
				fmt.Fprintf(a.errOut, "⚠ cap of %d application relays reached, %s/%s:%d not relayed\n", a.max, svc.namespace, svc.name, port)
			}
		}
	}
	a.forget(seen)
	return relays
}
