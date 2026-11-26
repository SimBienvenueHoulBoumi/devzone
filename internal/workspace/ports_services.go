package workspace

import (
	"bytes"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Fixed names of the watcher, as in manage/scripts/workspace/ports-workspace.sh.
const (
	modulesFile   = ".devzone.modules"
	pgAdminPath   = `jsonpath={.spec.ports[0].port}`
	argocdPath    = `jsonpath={.spec.ports[?(@.name=="https")].port}`
	argocdDefault = 8443
	// GitLab module relays: the web service on 8929 to its port 8181, and the
	// SSH shell on 2224, when the gitlab module is active (gitlab of
	// internal/domain).
	gitlabWebService = "svc/gitlab-webservice-default"
	gitlabSSHService = "svc/gitlab-gitlab-shell"
	gitlabWebLocal   = 8929
	gitlabWebRemote  = 8181
	gitlabSSHLocal   = 2224
	gitlabSSHRemote  = 2224
	// dialTimeout bounds the connection test of portTaken: a closed local port
	// answers at once, only a filtered one waits.
	dialTimeout = 200 * time.Millisecond
)

// podInternalPorts are the pod ports never relayed: kubedock and buildkit
// (PW_INTERNAL).
var podInternalPorts = map[int]bool{2475: true, 1234: true}

// relayService is a devzone service to relay: local port, namespace, target
// ("svc/name") and remote port, 0 meaning the same as the local port.
type relayService struct {
	local     int
	namespace string
	target    string
	remote    int
}

// watcherContext returns the kubectl arguments that select the devzone context
// when kubectl lists exactly that name, and none otherwise, so the current
// context is used (pw_ctx). The status of kubectl is ignored, as grep decides in
// the shell: a failing call lists nothing.
func watcherContext(r Runner) []string {
	var out bytes.Buffer
	_, _ = r.Kubectl([]string{"config", "get-contexts", "-o", "name"}, nil, &out, io.Discard)
	for _, line := range strings.Split(out.String(), "\n") {
		if line == "devzone" {
			return []string{"--context", "devzone"}
		}
	}
	return nil
}

// watcherKubectl runs kubectl with the context flag in front and returns its
// standard output, its status and the error of a call that could not start
// (pw_kubectl). The flag is looked up on every call, as the shell does.
func watcherKubectl(r Runner, args ...string) (string, int, error) {
	var out bytes.Buffer
	status, err := r.Kubectl(append(watcherContext(r), args...), nil, &out, io.Discard)
	return out.String(), status, err
}

// toPort converts a string made only of digits to a port, and tells whether it
// was one: the shell accepts only that before relaying anything it has read.
func toPort(s string) (int, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	port, err := strconv.Atoi(s)
	return port, err == nil
}

// serviceNumber reads a port with kubectl and returns it when the answer is
// entirely numeric (an absent service or a failing call give false).
func serviceNumber(r Runner, ns, service, path string) (int, bool) {
	out, _, err := watcherKubectl(r, "--namespace", ns, "get", "svc", service, "-o", path)
	if err != nil {
		return 0, false
	}
	return toPort(strings.TrimRight(out, "\n"))
}

// moduleLines returns the lines of the modules file; a missing file has none.
func moduleLines(file string) map[string]bool {
	lines := map[string]bool{}
	data, err := os.ReadFile(file)
	if err != nil {
		return lines
	}
	for _, line := range strings.Split(string(data), "\n") {
		lines[line] = true
	}
	return lines
}

// moduleOn tells whether the file has the whole line key=on, key=true or
// key=oui, the values the shell accepts (grep -x).
func moduleOn(lines map[string]bool, key string) bool {
	return lines[key+"=on"] || lines[key+"=true"] || lines[key+"=oui"]
}

// watchedServices lists the devzone services to relay, from the modules file
// (pw_services), in this order: postgres on 5432, pgAdmin when its service
// answers with a number, mysql on 3306, the GitLab relays (web on 8929 to its
// port 8181, SSH on 2224) when the gitlab module is active, then the Argo CD
// interface (https port of svc/argocd-server) on DEVZONE_ARGOCD_PORT (8443 by
// default) unless the line argocd=off is there. A value of DEVZONE_ARGOCD_PORT
// that is not a number gives the default, where the shell would print it as it
// is.
func watchedServices(r Runner, file string) []relayService {
	var services []relayService
	lines := moduleLines(file)
	if moduleOn(lines, "postgres") {
		services = append(services, relayService{local: 5432, namespace: "devzone-postgres", target: "svc/postgres"})
		if port, ok := serviceNumber(r, "devzone-postgres", "pgadmin", pgAdminPath); ok {
			services = append(services, relayService{local: port, namespace: "devzone-postgres", target: "svc/pgadmin"})
		}
	}
	if moduleOn(lines, "mysql") {
		services = append(services, relayService{local: 3306, namespace: "devzone-mysql", target: "svc/mysql"})
	}
	if moduleOn(lines, "gitlab") {
		namespace := gitlabNamespace()
		services = append(services, relayService{local: gitlabWebLocal, namespace: namespace, target: gitlabWebService, remote: gitlabWebRemote})
		services = append(services, relayService{local: gitlabSSHLocal, namespace: namespace, target: gitlabSSHService, remote: gitlabSSHRemote})
	}
	if !lines["argocd=off"] {
		if port, ok := serviceNumber(r, "devzone-argocd", "argocd-server", argocdPath); ok {
			local, valid := toPort(os.Getenv("DEVZONE_ARGOCD_PORT"))
			if !valid {
				local = argocdDefault
			}
			services = append(services, relayService{local: local, namespace: "devzone-argocd", target: "svc/argocd-server", remote: port})
		}
	}
	return services
}

// gitlabNamespace returns the namespace of the GitLab instance relayed by the
// watcher: devzone-gitlab plus the instance suffix, the same rule as the
// gitlab module of internal/domain/gitlab (DEVZONE_INSTANCE, "devzone" without
// suffix).
func gitlabNamespace() string {
	return "devzone-gitlab" + instanceSuffix()
}

// instanceSuffix returns the instance suffix of a devzone module: the value of
// DEVZONE_INSTANCE, empty and "devzone" without suffix, like the calculation of
// the gitlab module of internal/domain/gitlab.
func instanceSuffix() string {
	instance := os.Getenv("DEVZONE_INSTANCE")
	if instance != "" && instance != "devzone" {
		return "-" + instance
	}
	return ""
}

// podPorts lists the TCP ports of 1024 and above that listen in the workspace
// pod (pw_pod_ports): the last colon-separated part of the fourth column of
// "ss -ltnH", unique, in numeric order, without the internal ports. Lines that
// are not numeric are ignored. A failing call gives no port, where the shell
// would still use the output kubectl printed before failing.
func podPorts(r Runner) []int {
	out, status, err := watcherKubectl(r, "--namespace", namespace, "exec", pod, "-c", container, "--", "ss", "-ltnH")
	if err != nil || status != 0 {
		return nil
	}
	seen := map[int]bool{}
	var ports []int
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		address := fields[3]
		port, ok := toPort(address[strings.LastIndex(address, ":")+1:])
		if !ok || port < localMin || podInternalPorts[port] || seen[port] {
			continue
		}
		seen[port] = true
		ports = append(ports, port)
	}
	sort.Ints(ports)
	return ports
}

// portTaken tells whether port is already in use on the workstation (pw_taken).
// The shell asks lsof for any TCP listener on the port, or nc when lsof is
// missing. Two tests give the same answer on every platform, Windows included:
// a connection to 127.0.0.1 or ::1 succeeds when something listens on any
// address of the machine (a listener on all addresses answers on both), and
// listening on 127.0.0.1 fails when the port is held. Listening alone is not
// enough: on macOS a listener on all addresses does not stop a program from
// listening on 127.0.0.1 as well, so a port such as 5000 would look free.
// A port below 1024 needs privileges: it counts as taken for a normal user.
func portTaken(port int) bool {
	number := strconv.Itoa(port)
	for _, host := range []string{"127.0.0.1", "::1"} {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, number), dialTimeout)
		if err == nil {
			_ = conn.Close()
			return true
		}
	}
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", number))
	if err != nil {
		return true
	}
	_ = listener.Close()
	return false
}
