package workspace

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// scenario is what the cluster, the workstation and the modules file hold for
// a comparison of the services, pod ports and ready Services with bash
type scenario struct {
	name      string
	modules   string
	noModules bool
	contexts  string
	svc       string
	ready     string
	readyFail bool
	pgadmin   string
	argocd    string
	ss        string
	ssFail    bool
	argoPort  string
}

// fake returns the Runner that answers like the fake kubectl of the harness
func (s scenario) fake() *fakeRunner {
	fail := func(on bool) int {
		if on {
			return 1
		}
		return 0
	}
	return &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: s.contexts},
		{match: "get endpointslices", stdout: s.ready, status: fail(s.readyFail)},
		{match: "get svc -A", stdout: s.svc},
		{match: "svc pgadmin", stdout: s.pgadmin},
		{match: "svc argocd-server", stdout: s.argocd},
		{match: "ss -ltnH", stdout: s.ss, status: fail(s.ssFail)},
	}}
}

// env returns the variables that make the fake kubectl answer as the scenario
func (s scenario) env() []string {
	flag := func(on bool) string {
		if on {
			return "1"
		}
		return ""
	}
	return []string{
		"FAKE_CONTEXTS=" + s.contexts, "FAKE_SVC=" + s.svc, "FAKE_READY=" + s.ready,
		"FAKE_READY_FAIL=" + flag(s.readyFail), "FAKE_PGADMIN=" + s.pgadmin, "FAKE_ARGO=" + s.argocd,
		"FAKE_SS=" + s.ss, "FAKE_SS_FAIL=" + flag(s.ssFail), "DEVZONE_ARGOCD_PORT=" + s.argoPort,
	}
}

// isGitlabRelay tells whether the service is a relay of the GitLab module, put
// in the watcher by this port since #897: the bash original does not relay it
// yet (it will from #883), so the comparisons with it exclude this relay only.
func isGitlabRelay(svc relayService) bool {
	return svc.target == "svc/gitlab-webservice-default" || svc.target == "svc/gitlab-gitlab-shell"
}

// goText runs the Go functions and prints what the bash body of
// TestServicesMatchBash prints: services, pod ports, ready Services (sorted)
// and the status of pa_ready, then the discovery call
func (s scenario) goText(file string) (string, []string) {
	f := s.fake()
	var b strings.Builder
	b.WriteString("services\n")
	for _, svc := range watchedServices(f, file) {
		if isGitlabRelay(svc) {
			continue // the bash original relays GitLab from #883, not before
		}
		line := strconv.Itoa(svc.local) + "|" + svc.namespace + "|" + svc.target
		if svc.remote != 0 {
			line += "|" + strconv.Itoa(svc.remote)
		}
		b.WriteString(line + "\n")
	}
	b.WriteString("pods\n")
	for _, p := range podPorts(f) {
		b.WriteString(strconv.Itoa(p) + "\n")
	}
	b.WriteString("ready\n")
	ready, err := readyServices(f)
	var keys []string
	for key := range ready {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		b.WriteString(key + "\n")
	}
	if err != nil {
		b.WriteString("rc=1\n")
	} else {
		b.WriteString("rc=0\n")
	}
	discoverServices(f)
	return b.String(), f.calls
}

// TestServicesMatchBash runs pw_services, pw_pod_ports, pa_ready and pa_discover
// of the bash original with a fake kubectl, and the Go functions with a fake
// Runner, on the same answers: the outputs and every kubectl call (arguments,
// context flag, order) must be identical
func TestServicesMatchBash(t *testing.T) {
	ss := "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n" +
		"LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:*\nLISTEN 0 4096 *:8080 *:*\nLISTEN 0 4096 [::]:8080 [::]:*\n" +
		"LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:1023 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:1024 0.0.0.0:*\n" +
		"LISTEN 0 4096 0.0.0.0:2475 0.0.0.0:*\nLISTEN 0 4096 [::1]:1234 [::]:*\nLISTEN 0 4096 0.0.0.0:http 0.0.0.0:*\n" +
		"LISTEN 0 4096 [fe80::1%eth0]:9000 [::]:*\nLISTEN 0 4096 nocolon 0.0.0.0:*\nLISTEN 0 4096\n\nLISTEN 0 4096 0.0.0.0:10 x\n"
	ready := "shop|web|true,false,\nshop|web|false,\nshop|db|false,false,\nshop|none|\n|web|true,\nshop||true,\nmon|prom|false,true,\n\nbare\n"
	base := scenario{contexts: "minikube\n", svc: "shop|web|10.0.0.1|ClusterIP||80/TCP,\n", ready: ready, pgadmin: "5050", argocd: "443", ss: ss}
	with := func(name string, change func(*scenario)) scenario {
		s := base
		s.name = name
		change(&s)
		return s
	}
	scenarios := []scenario{
		with("no modules, no context", func(s *scenario) {}),
		with("devzone context", func(s *scenario) { s.contexts = "minikube\ndevzone\n"; s.modules = "postgres=on\nmysql=on\n" }),
		with("devzone with spaces", func(s *scenario) { s.contexts = " devzone\ndevzone \n"; s.modules = "mysql=on\n" }),
		with("devzone2 context", func(s *scenario) { s.contexts = "devzone2\n"; s.modules = "postgres=true\n" }),
		with("postgres oui, mysql true", func(s *scenario) { s.modules = "mysql=true\npostgres=oui" }),
		with("whole lines only", func(s *scenario) { s.modules = " postgres=on\nmysql=on \nxmysql=on\nargocd=off \n" }),
		with("crlf modules", func(s *scenario) { s.modules = "postgres=on\r\nargocd=off\r\n" }),
		with("argocd off", func(s *scenario) { s.modules = "argocd=off\npostgres=on\n" }),
		with("argocd port", func(s *scenario) { s.argoPort = "9443"; s.argocd = "8080\n" }),
		with("pgadmin absent", func(s *scenario) { s.modules = "postgres=on\n"; s.pgadmin = "" }),
		with("pgadmin not numeric", func(s *scenario) { s.modules = "postgres=on\n"; s.pgadmin = "Error from server" }),
		with("argocd not numeric", func(s *scenario) { s.argocd = "" }),
		with("no modules file", func(s *scenario) { s.noModules = true }),
		with("ready fails", func(s *scenario) { s.readyFail = true }),
		with("ss fails", func(s *scenario) { s.ssFail = true; s.contexts = "devzone" }),
		with("nothing ready", func(s *scenario) { s.ready = "shop|db|false,\n" }),
		with("gitlab on", func(s *scenario) { s.modules = "gitlab=on\n" }),
		with("gitlab off", func(s *scenario) { s.modules = "gitlab=off\n" }),
	}
	h := newBashHarness(t)
	body := `echo services; pw_services; echo pods; pw_pod_ports; echo ready
out="$(pa_ready)"; rc=$?; for k in $out; do echo "$k"; done | sort; echo "rc=$rc"; pa_discover >/dev/null`
	for _, s := range scenarios {
		file := filepath.Join(h.dir, ".devzone.modules")
		_ = os.Remove(file)
		if !s.noModules {
			if err := os.WriteFile(file, []byte(s.modules), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		_ = os.Remove(filepath.Join(h.dir, "kubectl.log"))
		t.Setenv("DEVZONE_ARGOCD_PORT", s.argoPort)
		wantText, wantCalls := s.goText(file)
		env := append(s.env(), "FAKE_LOG="+filepath.Join(h.dir, "kubectl.log"))
		gotText := h.run(body, "", env...)
		log, _ := os.ReadFile(filepath.Join(h.dir, "kubectl.log"))
		if gotText != wantText {
			t.Errorf("%s: output differs\nbash:\n%s\nGo:\n%s", s.name, gotText, wantText)
		}
		if got, want := string(log), strings.Join(wantCalls, "\n")+"\n"; got != want {
			t.Errorf("%s: kubectl calls differ\nbash:\n%s\nGo:\n%s", s.name, got, want)
		}
	}
}
