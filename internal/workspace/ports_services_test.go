package workspace

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestContextFlag checks that only a context named exactly devzone is selected
func TestContextFlag(t *testing.T) {
	devzone := []string{"--context", "devzone"}
	cases := []struct {
		name string
		r    reply
		want []string
	}{
		{"listed", reply{stdout: "minikube\ndevzone\n"}, devzone},
		{"alone without newline", reply{stdout: "devzone"}, devzone},
		{"other names", reply{stdout: "minikube\ndevzone2\nmy-devzone\n"}, nil},
		{"spaces around", reply{stdout: " devzone\n"}, nil},
		{"none", reply{}, nil},
		{"failing call", reply{status: 1}, nil},
		{"call that cannot start", reply{err: errors.New("no kubectl")}, nil},
	}
	for _, c := range cases {
		c.r.match = "config get-contexts -o name"
		f := &fakeRunner{replies: []reply{c.r}}
		if got := watcherContext(f); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: watcherContext = %v, want %v", c.name, got, c.want)
		}
	}
}

// servicesFake answers the kubectl calls of watchedServices: no devzone context,
// the given pgAdmin and Argo CD answers
func servicesFake(pgadmin, argocd string) *fakeRunner {
	return &fakeRunner{replies: []reply{
		{match: "get svc pgadmin", stdout: pgadmin},
		{match: "get svc argocd-server", stdout: argocd},
		{match: "config get-contexts"},
	}}
}

// modulesIn writes a modules file in a temporary folder and returns its path
func modulesIn(t *testing.T, content string) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), ".devzone.modules")
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return file
}

// TestWatchedServices checks the services that each modules file gives
func TestWatchedServices(t *testing.T) {
	pg := relayService{5432, "devzone-postgres", "svc/postgres", 0}
	pgadmin := relayService{5050, "devzone-postgres", "svc/pgadmin", 0}
	my := relayService{3306, "devzone-mysql", "svc/mysql", 0}
	argo := relayService{8443, "devzone-argocd", "svc/argocd-server", 443}
	cases := []struct {
		name, modules, pgadmin, argocd string
		want                           []relayService
	}{
		{"empty file", "", "5050", "443", []relayService{argo}},
		{"postgres on", "postgres=on\n", "5050", "", []relayService{pg, pgadmin}},
		{"postgres true", "x=1\npostgres=true\n", "", "", []relayService{pg}},
		{"postgres oui, no final newline", "postgres=oui", "5050\n", "", []relayService{pg, pgadmin}},
		{"postgres off", "postgres=off\n", "5050", "", nil},
		{"postgres line not whole", " postgres=on\nxpostgres=on\npostgres=on \n", "5050", "", nil},
		{"pgadmin not numeric", "postgres=on\n", "no svc", "", []relayService{pg}},
		{"mysql on", "mysql=on\n", "", "", []relayService{my}},
		{"mysql true and oui", "mysql=oui\nmysql=true\n", "", "", []relayService{my}},
		{"mysql other value", "mysql=yes\n", "", "", nil},
		{"all modules", "postgres=on\nmysql=on\n", "5050", "443", []relayService{pg, pgadmin, my, argo}},
		{"argocd off", "argocd=off\n", "", "443", nil},
		{"argocd off with a space", "argocd=off \n", "", "443", []relayService{argo}},
		{"argocd not numeric", "", "", "<none>", nil},
		{"argocd port read", "", "", "8080", []relayService{{8443, "devzone-argocd", "svc/argocd-server", 8080}}},
		{"crlf lines", "postgres=on\r\n", "5050", "", nil},
	}
	for _, c := range cases {
		t.Setenv("DEVZONE_ARGOCD_PORT", "")
		got := watchedServices(servicesFake(c.pgadmin, c.argocd), modulesIn(t, c.modules))
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// TestWatchedServicesCalls checks the exact kubectl calls, context flag first
func TestWatchedServicesCalls(t *testing.T) {
	t.Setenv("DEVZONE_ARGOCD_PORT", "")
	f := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "devzone\n"},
		{match: "pgadmin", stdout: "5050"},
		{match: "argocd-server", stdout: "443"},
	}}
	watchedServices(f, modulesIn(t, "postgres=on\n"))
	var calls []string
	for _, c := range f.calls {
		if !strings.HasPrefix(c, "config ") {
			calls = append(calls, c)
		}
	}
	want := []string{
		"--context devzone --namespace devzone-postgres get svc pgadmin -o jsonpath={.spec.ports[0].port}",
		`--context devzone --namespace devzone-argocd get svc argocd-server -o jsonpath={.spec.ports[?(@.name=="https")].port}`,
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
}

// TestWatchedServicesArgocdPort checks DEVZONE_ARGOCD_PORT and its fallback
func TestWatchedServicesArgocdPort(t *testing.T) {
	for value, want := range map[string]int{"9000": 9000, "": 8443, "abc": 8443} {
		t.Setenv("DEVZONE_ARGOCD_PORT", value)
		got := watchedServices(servicesFake("", "443"), modulesIn(t, ""))
		if len(got) != 1 || got[0].local != want {
			t.Errorf("DEVZONE_ARGOCD_PORT=%q: got %v, want local %d", value, got, want)
		}
	}
}

// TestWatchedServicesMissingFile checks that a missing modules file is not an error
func TestWatchedServicesMissingFile(t *testing.T) {
	t.Setenv("DEVZONE_ARGOCD_PORT", "")
	got := watchedServices(servicesFake("5050", "443"), filepath.Join(t.TempDir(), "absent"))
	if len(got) != 1 || got[0].target != "svc/argocd-server" {
		t.Fatalf("got %v", got)
	}
}

// TestPodPorts checks the ports read from ss: last colon part, 1024 and above,
// no internal port, unique, numeric order, non-numeric lines ignored
func TestPodPorts(t *testing.T) {
	ss := strings.Join([]string{
		"LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:*",
		"LISTEN 0 4096 *:8080 *:*",
		"LISTEN 0 4096 [::]:8080 [::]:*",
		"LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*",
		"LISTEN 0 4096 0.0.0.0:1023 0.0.0.0:*",
		"LISTEN 0 4096 0.0.0.0:1024 0.0.0.0:*",
		"LISTEN 0 4096 0.0.0.0:2475 0.0.0.0:*",
		"LISTEN 0 4096 [::1]:1234 [::]:*",
		"LISTEN 0 4096 0.0.0.0:http 0.0.0.0:*",
		"LISTEN 0 4096 [fe80::1%eth0]:9000 [::]:*",
		"LISTEN 0 4096 nocolon 0.0.0.0:*",
		"LISTEN 0 4096",
		"",
		"LISTEN 0 4096 0.0.0.0:300000 0.0.0.0:*",
	}, "\n") + "\n"
	f := &fakeRunner{replies: []reply{{match: "ss -ltnH", stdout: ss}, {match: "config get-contexts"}}}
	want := []int{1024, 3000, 8080, 9000, 300000}
	if got := podPorts(f); !reflect.DeepEqual(got, want) {
		t.Fatalf("podPorts = %v, want %v", got, want)
	}
	call := f.calls[len(f.calls)-1]
	if call != "--namespace devzone-workspace exec devzone-workspace-0 -c workspace -- ss -ltnH" {
		t.Fatalf("call = %q", call)
	}
}

// TestPodPortsFailure checks that a failing call gives no port
func TestPodPortsFailure(t *testing.T) {
	for _, r := range []reply{{status: 1, stdout: "LISTEN 0 1 0.0.0.0:3000 x\n"}, {err: errors.New("cannot start")}} {
		r.match = "ss -ltnH"
		f := &fakeRunner{replies: []reply{r, {match: "config get-contexts"}}}
		if got := podPorts(f); len(got) != 0 {
			t.Errorf("podPorts = %v, want none", got)
		}
	}
}

// TestPortTaken checks portTaken on a port that this test really holds, then on
// the same port once released
func TestPortTaken(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip("cannot listen on 127.0.0.1:", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if !portTaken(port) {
		t.Errorf("port %d is held, portTaken = false", port)
	}
	_ = listener.Close()
	if portTaken(port) {
		t.Errorf("port %d is released, portTaken = true", port)
	}
}

// TestPortTakenWildcard checks that a listener on all addresses makes the port
// taken, and one on ::1 only when the system has IPv6: listening on 127.0.0.1
// alone would miss them on macOS
func TestPortTakenWildcard(t *testing.T) {
	cases := []struct{ network, address string }{
		{"tcp", ":0"},
		{"tcp6", "[::1]:0"},
	}
	for _, c := range cases {
		listener, err := net.Listen(c.network, c.address)
		if err != nil {
			t.Logf("skip %s %s: %v", c.network, c.address, err)
			continue
		}
		port := listener.Addr().(*net.TCPAddr).Port
		if !portTaken(port) {
			t.Errorf("%s %s held on port %d, portTaken = false", c.network, c.address, port)
		}
		_ = listener.Close()
		if portTaken(port) {
			t.Errorf("%s %s released on port %d, portTaken = true", c.network, c.address, port)
		}
	}
}
