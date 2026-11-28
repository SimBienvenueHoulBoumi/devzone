package workspace

import (
	"errors"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// portsSkipNamespaces lists the namespaces never relayed as applications: the
// system ones and those of the devzone modules, which have their own relay or
// no interface (PA_NS_SKIP in manage/scripts/workspace/ports-apps.sh). The
// spaces around each name make a plain substring test exact, as the shell does.
const portsSkipNamespaces = " kube-system kube-public kube-node-lease local-path-storage devzone-system " + config.NamespaceWorkspace + " " + config.NamespacePostgres + " devzone-mysql " + config.NamespaceArgoCD + " " + config.NamespaceGitLab + " devzone-llm "

// Local port choice (pa_new): the first port tried for a privileged Service
// port is port + localOffset, a candidate past localMax restarts at localWrap,
// and at most localTries candidates are tested.
const (
	localMin    = 1024
	localOffset = 8000
	localMax    = 65000
	localWrap   = 20000
	localTries  = 60000
)

// Kubernetes queries of the watcher, copied from pa_discover and pa_ready.
const (
	discoverJSONPath = `jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.clusterIP}|{.spec.type}|{.metadata.annotations.devzone\.io/relay}|{range .spec.ports[*]}{.port}/{.protocol},{end}{"\n"}{end}`
	readyJSONPath    = `jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.labels.kubernetes\.io/service-name}|{range .endpoints[*]}{.conditions.ready},{end}{"\n"}{end}`
)

// errEndpointsUnreadable tells that the endpoint slices could not be read. The
// shell then relays every Service, so the caller decides, not this package.
var errEndpointsUnreadable = errors.New("endpointslices unreadable")

// errNoFreePort tells that no local port was free after localTries candidates.
var errNoFreePort = errors.New("no free local port")

// discoveredService is one line of pa_discover: a Service of the cluster and
// its TCP ports. The relay annotation is empty when the Service has none.
type discoveredService struct {
	namespace, name, clusterIP, svcType, annotation string
	ports                                           []int
}

// serviceExcluded tells whether a Service is never relayed as an application
// (pa_excluded): a skipped namespace, default/kubernetes, the annotation
// devzone.io/relay set to false, an ExternalName Service (nothing to reach in
// the cluster) or one without address (headless, None).
func serviceExcluded(ns, name, clusterIP, svcType, annotation string) bool {
	if strings.Contains(portsSkipNamespaces, " "+ns+" ") {
		return true
	}
	if ns+"/"+name == "default/kubernetes" {
		return true
	}
	return annotation == "false" || svcType == "ExternalName" || clusterIP == "" || clusterIP == "None"
}

// parseDiscovered reads the output of pa_discover: one line
// "namespace|name|clusterIP|type|annotation|port/proto,port/proto," per Service.
// Lines without namespace are ignored, a missing field is empty, and only the
// ports "<digits>/TCP" are kept, in the order given. Exclusion is not applied
// here: the caller applies serviceExcluded.
func parseDiscovered(out string) []discoveredService {
	var services []discoveredService
	for _, line := range strings.Split(out, "\n") {
		fields := strings.SplitN(line, "|", 6)
		for len(fields) < 6 {
			fields = append(fields, "")
		}
		if fields[0] == "" {
			continue
		}
		services = append(services, discoveredService{
			namespace: fields[0], name: fields[1], clusterIP: fields[2],
			svcType: fields[3], annotation: fields[4], ports: tcpPorts(fields[5]),
		})
	}
	return services
}

// tcpPorts keeps the numeric TCP ports of a list "80/TCP,53/UDP,": any other
// protocol, or a port that is not entirely numeric, is dropped.
func tcpPorts(list string) []int {
	var ports []int
	for _, item := range strings.Fields(strings.ReplaceAll(list, ",", " ")) {
		number, ok := strings.CutSuffix(item, "/TCP")
		if !ok {
			continue
		}
		if port, ok := toPort(number); ok {
			ports = append(ports, port)
		}
	}
	return ports
}

// discoverServices lists the Services of the cluster (pa_discover). As in the
// shell, the output is used whatever the status of kubectl, and a call that
// fails gives no Service.
func discoverServices(r Runner) []discoveredService {
	out, _, _ := watcherKubectl(r, "get", "svc", "-A", "-o", discoverJSONPath)
	return parseDiscovered(out)
}

// parseReady reads the lines "namespace|service|true,false," of pa_ready and
// returns the set of "namespace/service" with at least one ready endpoint. A
// line without namespace or without service is ignored; "true" anywhere in the
// conditions is enough, so a Service with several slices is ready if one is.
func parseReady(out string) map[string]bool {
	ready := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.SplitN(line, "|", 3)
		for len(fields) < 3 {
			fields = append(fields, "")
		}
		if fields[0] == "" || fields[1] == "" {
			continue
		}
		if strings.Contains(fields[2], "true") {
			ready[fields[0]+"/"+fields[1]] = true
		}
	}
	return ready
}

// readyServices reads the endpoint slices of the cluster (pa_ready). A call that
// fails returns errEndpointsUnreadable: the shell then relays every Service, and
// only the caller knows whether to do so.
func readyServices(r Runner) (map[string]bool, error) {
	out, status, err := watcherKubectl(r, "get", "endpointslices", "-A", "-o", readyJSONPath)
	if err != nil || status != 0 {
		return nil, errEndpointsUnreadable
	}
	return parseReady(out), nil
}

// localPortFree tells whether local port can serve an application (pa_free): it
// is not in used (ports already wanted or excluded) and not taken on the
// workstation, which taken tells (injected, so tests need no real port).
func localPortFree(port int, used []int, taken func(int) bool) bool {
	for _, u := range used {
		if u == port {
			return false
		}
	}
	return !taken(port)
}

// newLocalPort chooses the local port of a Service port (pa_new). The port
// itself serves when it is not privileged and free, so that 5432 stays 5432.
// Otherwise candidates start at port + localOffset (80 gives 8080) and
// increase one by one, back to localWrap past localMax, for localTries tries.
// errNoFreePort is returned when none is free.
func newLocalPort(port int, used []int, taken func(int) bool) (int, error) {
	if port >= localMin && localPortFree(port, used, taken) {
		return port, nil
	}
	candidate := port + localOffset
	if candidate > localMax {
		candidate = localWrap
	}
	for i := 0; i < localTries; i++ {
		if localPortFree(candidate, used, taken) {
			return candidate, nil
		}
		candidate++
		if candidate > localMax {
			candidate = localWrap
		}
	}
	return 0, errNoFreePort
}
