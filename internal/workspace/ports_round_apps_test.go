package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// appsHarness runs appRound against a fake Runner, a temporary state folder and
// a workstation where only the ports of taken are in use.
type appsHarness struct {
	t      *testing.T
	dir    string
	modul  string
	svc    string
	ready  string
	failed bool
	taken  map[int]bool
	max    int
	fake   *fakeRunner
}

func newAppsHarness(t *testing.T) *appsHarness {
	t.Helper()
	dir := t.TempDir()
	return &appsHarness{t: t, dir: filepath.Join(dir, "state"), modul: filepath.Join(dir, "modules"), taken: map[int]bool{}, max: appsMax}
}

// run does one round with the current answers and returns the relays and what
// went to the error output.
func (h *appsHarness) run(wanted ...int) ([]relayService, string) {
	h.t.Helper()
	status := 0
	if h.failed {
		status = 1
	}
	h.fake = &fakeRunner{replies: []reply{
		{match: "get endpointslices", stdout: h.ready, status: status},
		{match: "get svc -A", stdout: h.svc},
	}}
	var errOut bytes.Buffer
	a := appRound{runner: h.fake, dir: h.dir, modules: h.modul, taken: func(p int) bool { return h.taken[p] }, max: h.max, errOut: &errOut}
	return a.run(wanted), errOut.String()
}

// state returns the content of a state file, or "<none>" when it is missing.
func (h *appsHarness) state(rel string) string {
	data, err := os.ReadFile(filepath.Join(h.dir, rel))
	if err != nil {
		return "<none>"
	}
	return string(data)
}

func (h *appsHarness) names(sub string) []string {
	return stateNames(filepath.Join(h.dir, sub))
}

func TestAppRoundStableLocalPorts(t *testing.T) {
	h := newAppsHarness(t)
	h.svc = svcLine("shop", "web", 80) + svcLine("shop", "db", 5432) + svcLine("kube-system", "dns", 53) +
		"shop|ext|10.0.0.9|ExternalName||80/TCP,\nshop|udp|10.0.0.7|ClusterIP||53/UDP,\n"
	h.ready = readyLine("shop", "web") + readyLine("shop", "db") + readyLine("kube-system", "dns")
	got, warn := h.run(5432)
	want := []relayService{
		{local: 8080, namespace: "shop", target: "svc/web", remote: 80},
		{local: 13432, namespace: "shop", target: "svc/db", remote: 5432},
	}
	if !reflect.DeepEqual(got, want) || warn != "" {
		t.Fatalf("got %+v warn %q, want %+v", got, warn, want)
	}
	if h.state("apps/shop.web.80") != "8080" || h.state("apps/shop.db.5432") != "13432" {
		t.Fatalf("local ports not remembered: %v", h.names("apps"))
	}
	// the port 8080 becomes busy: the remembered port stays, it is not recomputed
	h.taken[8080] = true
	if again, _ := h.run(5432); !reflect.DeepEqual(again, want) {
		t.Fatalf("second round changed the ports: %+v", again)
	}
	// but a port that another service now wants is given up for a new one
	h.taken = map[int]bool{}
	if again, _ := h.run(5432, 8080); again[0].local != 8081 || h.state("apps/shop.web.80") != "8081" {
		t.Fatalf("remembered port used by a wanted port was kept: %+v", again)
	}
	if n := strings.Count(strings.Join(h.fake.calls, "\n"), "get svc -A"); n != 1 {
		t.Fatalf("%d discovery calls in one round, want 1", n)
	}
	if n := strings.Count(strings.Join(h.fake.calls, "\n"), "get endpointslices"); n != 1 {
		t.Fatalf("%d endpoint calls in one round, want 1", n)
	}
}

func TestAppRoundExcludedPorts(t *testing.T) {
	h := newAppsHarness(t)
	if err := os.WriteFile(h.modul, []byte("excluded_ports=1111\npostgres=on\nexcluded_ports=9000,9001,x=2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.svc = svcLine("shop", "a", 9000) + svcLine("shop", "b", 9001) + svcLine("shop", "c", 1111)
	h.ready = readyLine("shop", "a") + readyLine("shop", "b") + readyLine("shop", "c")
	got, _ := h.run()
	if got[0].local != 17000 || got[1].local != 17001 || got[2].local != 1111 {
		t.Fatalf("only the last excluded_ports line counts: %+v", got)
	}
	if want := []int{9000, 9001}; !reflect.DeepEqual(excludedPorts(h.modul)[:2], want) {
		t.Fatalf("excludedPorts = %v", excludedPorts(h.modul))
	}
}

func TestExcludedPortsParsing(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "m")
	write := func(s string) { _ = os.WriteFile(file, []byte(s), 0o644) }
	write("excluded_ports=1,2,, 3,abc,04,5=6\n")
	if got, want := excludedPorts(file), []int{1, 2, 3}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	write(" excluded_ports=1\nmy_excluded_ports=2\n")
	if got := excludedPorts(file); got != nil {
		t.Fatalf("line must start with excluded_ports=: %v", got)
	}
	if got := excludedPorts(filepath.Join(dir, "missing")); got != nil {
		t.Fatalf("missing file: %v", got)
	}
}

func TestAppRoundNoReadyPod(t *testing.T) {
	h := newAppsHarness(t)
	h.svc = svcLine("shop", "up", 6001) + svcLine("shop", "down", 6002)
	h.ready = readyLine("shop", "up") + "shop|down|false,\n"
	got, _ := h.run()
	if len(got) != 1 || got[0].target != "svc/up" {
		t.Fatalf("relays %+v", got)
	}
	if h.state("no-ready-pod/shop.down.6002") != "" || h.state("apps/shop.down.6002") != "6002" {
		t.Fatalf("marker or port missing: %v %v", h.names("no-ready-pod"), h.names("apps"))
	}
	if h.names("no-ready-pod")[0] != "shop.down.6002" || len(h.names("no-ready-pod")) != 1 {
		t.Fatalf("markers %v", h.names("no-ready-pod"))
	}
	h.ready += readyLine("shop", "down")
	if got, _ = h.run(); len(got) != 2 || len(h.names("no-ready-pod")) != 0 {
		t.Fatalf("recovered service: %+v %v", got, h.names("no-ready-pod"))
	}
}

func TestAppRoundUnreadableEndpoints(t *testing.T) {
	h := newAppsHarness(t)
	h.svc = svcLine("shop", "web", 6001)
	h.failed = true
	const warning = "⚠ endpointslices unreadable, ready pods not checked\n"
	got, warn := h.run()
	if len(got) != 1 || warn != warning || h.state("endpoints-unreadable") != "" {
		t.Fatalf("got %+v warn %q", got, warn)
	}
	if _, warn = h.run(); warn != "" {
		t.Fatalf("warning repeated: %q", warn)
	}
	h.failed = false
	h.ready = readyLine("shop", "web")
	if _, warn = h.run(); warn != "" || h.state("endpoints-unreadable") != "<none>" {
		t.Fatalf("marker kept after a good read: %q", warn)
	}
	h.failed = true
	if _, warn = h.run(); warn != warning {
		t.Fatalf("a new failure must warn again: %q", warn)
	}
}

func TestAppRoundCap(t *testing.T) {
	h := newAppsHarness(t)
	h.max = 2
	for _, p := range []int{6001, 6002, 6003, 6004} {
		h.svc += svcLine("shop", "s"+string(rune('a'+p-6001)), p)
		h.ready += readyLine("shop", "s"+string(rune('a'+p-6001)))
	}
	got, warn := h.run()
	if len(got) != 2 || strings.Count(warn, "\n") != 2 ||
		!strings.Contains(warn, "⚠ cap of 2 application relays reached, shop/sc:6003 not relayed\n") {
		t.Fatalf("got %d relays, warnings %q", len(got), warn)
	}
	if !reflect.DeepEqual(h.names("cap"), []string{"shop.sc.6003", "shop.sd.6004"}) {
		t.Fatalf("cap markers %v", h.names("cap"))
	}
	if _, warn = h.run(); warn != "" {
		t.Fatalf("cap warning repeated: %q", warn)
	}
	// the first service goes away: the third fits under the cap and loses its marker
	h.svc = strings.SplitAfterN(h.svc, "\n", 2)[1]
	got, warn = h.run()
	if len(got) != 2 || got[1].target != "svc/sc" || warn != "" || !reflect.DeepEqual(h.names("cap"), []string{"shop.sd.6004"}) {
		t.Fatalf("got %+v warn %q cap %v", got, warn, h.names("cap"))
	}
	// unready services count for nothing: with the cap at 1, the unready one is skipped
	h.max = 1
	h.ready = readyLine("shop", "sd")
	if got, _ = h.run(); len(got) != 1 || got[0].target != "svc/sd" {
		t.Fatalf("unready service used a slot: %+v", got)
	}
}

func TestAppRoundNoFreePort(t *testing.T) {
	h := newAppsHarness(t)
	h.svc = svcLine("shop", "web", 6001)
	h.ready = readyLine("shop", "web")
	h.run()
	h.taken = map[int]bool{}
	for p := 1; p <= 65535; p++ {
		h.taken[p] = true
	}
	_ = os.Remove(filepath.Join(h.dir, "apps", "shop.web.6001"))
	h.svc += svcLine("shop", "api", 7001)
	got, warn := h.run()
	if len(got) != 0 || warn != "⚠ no free local port for shop/web:6001\n⚠ no free local port for shop/api:7001\n" {
		t.Fatalf("got %+v warn %q", got, warn)
	}
}

func TestAppRoundForgetsGoneServices(t *testing.T) {
	h := newAppsHarness(t)
	h.svc = svcLine("shop", "web", 6001)
	h.ready = readyLine("shop", "web")
	for _, rel := range []string{"apps/old.svc.1", "cap/old.svc.1", "no-ready-pod/old.svc.1", "apps/.hidden"} {
		_ = os.MkdirAll(filepath.Dir(filepath.Join(h.dir, rel)), 0o755)
		_ = os.WriteFile(filepath.Join(h.dir, rel), []byte("9"), 0o644)
	}
	h.run()
	for _, rel := range []string{"apps/old.svc.1", "cap/old.svc.1", "no-ready-pod/old.svc.1"} {
		if h.state(rel) != "<none>" {
			t.Errorf("%s kept", rel)
		}
	}
	if h.state("apps/.hidden") != "9" || h.state("apps/shop.web.6001") != "6001" {
		t.Errorf("hidden file removed or live service lost: %v", h.names("apps"))
	}
	h.svc = ""
	h.run()
	if len(h.names("apps")) != 0 {
		t.Errorf("state of a gone Service kept: %v", h.names("apps"))
	}
}
