package gitlab

import (
	"fmt"
	"os"
	"strings"

	osexec "os/exec"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// relayDir returns the directory of the relay of a module (workspace/.<name>).
func (r *run) relayDir(name string) string {
	return r.root + "/workspace/." + name
}

// readPid returns the PID written by relayStart in the folder of the relay.
func (r *run) readPid(name string) string {
	data, err := os.ReadFile(r.relayDir(name) + "/relais.pid")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// relayActive reports whether the relay of a module is running
// (relay_active of cluster.sh). A test injects ProcessAlive, so no process is
// ever signalled by a test.
func (r *run) relayActive(name string) bool {
	pid := r.readPid(name)
	if pid == "" {
		return false
	}
	if r.opts.ProcessAlive != nil {
		return r.opts.ProcessAlive(pid)
	}
	return osexec.Command("kill", "-0", pid).Run() == nil
}

// relayScript is the loop of the relay started by relayStart (cluster.sh
// relay_start): it follows the ready pod behind the service, then restarts
// port-forward when the pod changes.
func relayScript() string {
	return `
        pod() {
            case "$2" in
                svc/*) kubectl --context "$0" -n "$1" get endpoints "${2#svc/}" -o jsonpath="{.subsets[*].addresses[*].targetRef.uid}" 2>/dev/null ;;
                *) echo fixe ;;
            esac
        }
        while :; do
            until [ -n "$(pod "$@")" ]; do sleep 2; done
            actuel="$(pod "$@")"
            kubectl --context "$0" -n "$1" port-forward --address 127.0.0.1 "$2" "${@:3}" &
            pf=$!
            while kill -0 "$pf" 2>/dev/null; do
                sleep 5
                [ "$(pod "$@")" = "$actuel" ] || { kill "$pf" 2>/dev/null; break; }
            done
            wait "$pf" 2>/dev/null
            sleep 1
        done`
}

// startRelay starts the detached loop of a relay and returns its PID. A test
// injects StartRelay and only records the command; the real path starts the
// process of the pod as cluster.sh did.
func (r *run) startRelay(name, dir string, args []string) (string, error) {
	if r.opts.StartRelay != nil {
		return r.opts.StartRelay(name, dir, args)
	}
	cmdLine := []string{"nohup", "bash", "-c", relayScript()}
	if _, err := osexec.LookPath("setsid"); err == nil {
		cmdLine = append([]string{"setsid"}, cmdLine...)
	}
	all := append(append([]string{}, cmdLine[1:]...), args...)
	cmd := osexec.Command(cmdLine[0], all...)
	logFile, err := os.Create(dir + "/relais.log")
	if err != nil {
		return "", err
	}
	cmd.Stdout, cmd.Stderr = logFile, logFile
	err = cmd.Start()
	_ = logFile.Close()
	if err != nil || cmd.Process == nil {
		return "", err
	}
	return itoa(cmd.Process.Pid), nil
}

// relayStart starts the port-forward relay of a service, idempotent
// (relay_start of cluster.sh): nothing when the relay runs, otherwise the
// detached loop is started and its PID is written in the folder of the relay.
func (r *run) relayStart(name, ctx, ns, target string, ports ...string) {
	dir := r.relayDir(name)
	_ = os.MkdirAll(dir, 0o755)
	if r.relayActive(name) {
		return
	}
	args := append([]string{ctx, ns, target}, ports...)
	pid, err := r.startRelay(name, dir, args)
	if err != nil || pid == "" {
		return
	}
	_ = os.WriteFile(dir+"/relais.pid", []byte(pid+"\n"), 0o644)
}

// itoa converts an int to a string (kept local to the relay helpers).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

// relayStop stops the relay of a module: the loop first (children with it),
// then the PID file is removed (relay_stop of cluster.sh).
func (r *run) relayStop(name string) {
	pid := r.readPid(name)
	if pid != "" {
		children := r.pgrepParent(pid)
		if r.opts.ProcessAlive == nil {
			_ = osexec.Command("kill", pid).Run()
			for _, child := range children {
				_ = osexec.Command("kill", child).Run()
			}
		}
	}
	_ = os.Remove(r.relayDir(name) + "/relais.pid")
}

// pgrepParent returns the PIDs whose parent is pid (pgrep -P).
func (r *run) pgrepParent(pid string) []string {
	res, err := r.runner().Run(r.ctx, "pgrep", []string{"-P", pid}, exec.Opts{})
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

// relayStatus reports the state of the two relays of the module: the exit
// status is 1 when at least one is stopped (gitlab_relay_status).
func (r *run) relayStatus() int {
	missing := ""
	if !r.relayActive("gitlab-web") {
		missing += " 8929"
	}
	if !r.relayActive("gitlab-ssh") {
		missing += " 2224"
	}
	if missing != "" {
		fmt.Fprintf(r.out(), "gitlab relay stopped on%s\n", missing)
		return 1
	}
	return 0
}

// gitlabRelayStart starts the two relays of the module: web and SSH
// (installation.sh gitlab_relay_start).
func (r *run) gitlabRelayStart() int {
	r.relayStart("gitlab-web", "devzone", r.namespace(), "svc/gitlab-webservice-default", "8929:8181")
	r.relayStart("gitlab-ssh", "devzone", r.namespace(), "svc/gitlab-gitlab-shell", "2224:22")
	return 0
}

// gitlabRelayStop stops the two relays of the module (gitlab_relay_stop).
func (r *run) gitlabRelayStop() {
	r.relayStop("gitlab-web")
	r.relayStop("gitlab-ssh")
}
