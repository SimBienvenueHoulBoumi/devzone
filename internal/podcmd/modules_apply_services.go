package podcmd

import (
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// applyGitlab installs or removes the GitLab module (apply_gitlab). The
// installer is skipped when the state is ready and the runner online.
func (m *modules) applyGitlab(verb string) int {
	out := m.ctx.Out
	if verb == "on" {
		current, _ := m.capture("gitlab", "status")
		if strings.Contains(current, "ready") && strings.Contains(current, "runner online") {
			fmt.Fprintln(out, "devzone : gitlab already active, nothing to do.")
			// /etc/hosts regenerated when the pod starts: gitlab.localhost is set again here too
			if code := m.call(out, "gitlab", "host-set"); code != 0 {
				return code
			}
			// Failure of an old run cleared: gitlab is ready (#366)
			m.clearMarker("gitlab")
			return 0
		}
		fmt.Fprintln(out, "devzone : activating gitlab via its installer…")
		if m.call(out, "gitlab", "install") != 0 {
			m.setMarker("gitlab")
			return 1
		}
		m.clearMarker("gitlab")
		return 0
	}
	// Disable gitlab only if its namespace still exists
	if m.call(out, "gitlab", "installed") == 0 {
		fmt.Fprintln(out, "devzone : deactivating gitlab…")
		if m.deleteData {
			return m.call(out, "gitlab", "uninstall", "--yes")
		}
		return m.call(out, "gitlab", "uninstall")
	}
	fmt.Fprintln(out, "devzone : gitlab already deactivated (no "+config.NamespaceGitLab+" namespace).")
	return 0
}

// applyPostgres installs the shared PostgreSQL (#280) on the cluster chosen at
// the first activation (--context, --confirm), or removes it (apply_postgres).
func (m *modules) applyPostgres(verb string, args []string) int {
	out, errOut := m.ctx.Out, m.ctx.Err
	if verb != "on" {
		if code := m.call(out, "postgres", "uninstall"); code != 0 {
			return code
		}
		m.clearMarker("postgres")
		return 0
	}
	wanted, confirmCtx, expect := "", "", ""
	for _, arg := range args {
		if expect != "" {
			switch expect {
			case "context":
				wanted = arg
			case "confirm":
				confirmCtx = arg
			}
			expect = ""
			continue
		}
		switch arg {
		case "--context":
			expect = "context"
		case "--confirm":
			expect = "confirm"
		default:
			fmt.Fprintf(errOut, "devzone : unknown argument: %s (devzone enable postgres --context CTX [--confirm CTX])\n", arg)
			m.writeValue("postgres", "off")
			return 2
		}
	}
	if expect != "" {
		fmt.Fprintf(errOut, "devzone : %s expects a context\n", expect)
		m.writeValue("postgres", "off")
		return 2
	}
	actual, _ := m.capture("kube", "saved")
	if wanted != "" && actual != "" && wanted != actual {
		fmt.Fprintf(errOut, "devzone : devzone services are on %s; to change: devzone cluster %s\n", actual, wanted)
		m.writeValue("postgres", "off")
		return 2
	}
	chooseArgs := []string{"kube", "choose", wanted}
	if confirmCtx != "" {
		chooseArgs = append(chooseArgs, "--confirm", confirmCtx)
	}
	chosen, code := m.capture(chooseArgs...)
	if code != 0 {
		m.writeValue("postgres", "off")
		return 2
	}
	// Choice kept before the installation: a resume targets the same cluster
	if code := m.call(out, "kube", "save", chosen); code != 0 {
		return code
	}
	current, _ := m.capture("postgres", "status")
	// "relay stopped" first: this line also starts with "ready on"
	switch {
	case strings.Contains(current, "relay stopped"):
		if code := m.call(out, "postgres", "relay-start"); code != 0 {
			return code
		}
		fmt.Fprintln(out, "devzone : postgres : relay restarted")
	case strings.HasPrefix(current, "ready on"):
		fmt.Fprintln(out, "devzone : postgres already active, nothing to do.")
	default:
		if m.call(out, "postgres", "install") != 0 {
			m.setMarker("postgres")
			return 1
		}
	}
	m.clearMarker("postgres")
	return 0
}

// applyMysql starts the catalog MySQL (#414) on the cluster kept in the state,
// or removes it: the volume and the databases stay unless DELETE_DATA (apply_mysql).
func (m *modules) applyMysql(verb string) int {
	out, errOut := m.ctx.Out, m.ctx.Err
	if verb == "on" {
		if m.clusterSaved() == "" {
			fmt.Fprintln(errOut, "devzone : mysql: no cluster chosen: devzone enable mysql")
			m.writeValue("mysql", "off")
			m.setMarker("mysql")
			return 2
		}
		current, _ := m.capture("mysql", "status")
		// "relay stopped" first: this line also starts with "ready on"
		switch {
		case strings.Contains(current, "relay stopped"):
			if code := m.call(out, "mysql", "relay-start"); code != 0 {
				return code
			}
			fmt.Fprintln(out, "devzone : mysql: relay restarted")
		case strings.HasPrefix(current, "ready on"):
			fmt.Fprintln(out, "devzone : mysql already active, nothing to do.")
		default:
			if m.call(out, "mysql", "install") != 0 {
				m.setMarker("mysql")
				return 1
			}
		}
		m.clearMarker("mysql")
		return 0
	}
	// Removal without deleting the data: volume kept (#441); the databases
	// only leave with a yes (confirmRemoval)
	if code := m.call(out, "catalog", "remove", "mysql"); code != 0 {
		return code
	}
	if m.deleteData {
		if code := m.call(out, "mysql", "delete-data", "--yes"); code != 0 {
			return code
		}
	}
	m.clearMarker("mysql")
	return 0
}
