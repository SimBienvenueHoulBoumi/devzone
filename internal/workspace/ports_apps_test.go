package workspace

import (
	"errors"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// TestServiceExcluded checks each exclusion rule of serviceExcluded, and that a
// plain Service is kept
func TestServiceExcluded(t *testing.T) {
	cases := []struct {
		name                             string
		ns, svc, ip, svcType, annotation string
		want                             bool
	}{
		{"plain service", "shop", "web", "10.0.0.1", "ClusterIP", "", false},
		{"annotation true", "shop", "web", "10.0.0.1", "ClusterIP", "true", false},
		{"annotation false", "shop", "web", "10.0.0.1", "ClusterIP", "false", true},
		{"external name", "shop", "web", "10.0.0.1", "ExternalName", "", true},
		{"load balancer", "shop", "web", "10.0.0.1", "LoadBalancer", "", false},
		{"no address", "shop", "web", "", "ClusterIP", "", true},
		{"headless", "shop", "web", "None", "ClusterIP", "", true},
		{"default kubernetes", "default", "kubernetes", "10.0.0.1", "ClusterIP", "", true},
		{"other default service", "default", "web", "10.0.0.1", "ClusterIP", "", false},
		{"kubernetes elsewhere", "shop", "kubernetes", "10.0.0.1", "ClusterIP", "", false},
		{"partial namespace name", "kube", "web", "10.0.0.1", "ClusterIP", "", false},
		{"empty namespace", "", "web", "10.0.0.1", "ClusterIP", "", false},
	}
	for _, c := range cases {
		if got := serviceExcluded(c.ns, c.svc, c.ip, c.svcType, c.annotation); got != c.want {
			t.Errorf("%s: serviceExcluded = %v, want %v", c.name, got, c.want)
		}
	}
	for _, ns := range strings.Fields(portsSkipNamespaces) {
		if !serviceExcluded(ns, "web", "10.0.0.1", "ClusterIP", "") {
			t.Errorf("namespace %s must be skipped", ns)
		}
	}
	if got := len(strings.Fields(portsSkipNamespaces)); got != 11 {
		t.Errorf("skipped namespaces = %d, want 11", got)
	}
}

// TestParseDiscovered checks the split of the lines of pa_discover
func TestParseDiscovered(t *testing.T) {
	out := strings.Join([]string{
		"shop|web|10.0.0.1|ClusterIP||80/TCP,443/TCP,",
		"",
		"shop|dns|10.0.0.2|ClusterIP|false|53/UDP,53/TCP,",
		"|orphan|10.0.0.3|ClusterIP||80/TCP,",
		"shop|odd|10.0.0.4|ClusterIP||8x/TCP,/TCP,90/TCP,91/SCTP,92,",
		"shop|short",
		"shop|many|10.0.0.5|NodePort|true|1/TCP,2/TCP,",
	}, "\n") + "\n"
	want := []discoveredService{
		{"shop", "web", "10.0.0.1", "ClusterIP", "", []int{80, 443}},
		{"shop", "dns", "10.0.0.2", "ClusterIP", "false", []int{53}},
		{"shop", "odd", "10.0.0.4", "ClusterIP", "", []int{90}},
		{"shop", "short", "", "", "", nil},
		{"shop", "many", "10.0.0.5", "NodePort", "true", []int{1, 2}},
	}
	if got := parseDiscovered(out); !reflect.DeepEqual(got, want) {
		t.Fatalf("parseDiscovered =\n%v\nwant\n%v", got, want)
	}
	if got := parseDiscovered(""); len(got) != 0 {
		t.Fatalf("empty output gave %v", got)
	}
}

// TestDiscoverServices checks the kubectl call of discoverServices and that the
// output is used whatever the status
func TestDiscoverServices(t *testing.T) {
	f := &fakeRunner{replies: []reply{
		{match: "get svc -A", stdout: "shop|web|10.0.0.1|ClusterIP||80/TCP,\n", status: 1},
		{match: "config get-contexts", stdout: "devzone\n"},
	}}
	got := discoverServices(f)
	if len(got) != 1 || got[0].name != "web" {
		t.Fatalf("discoverServices = %v", got)
	}
	want := "--context devzone get svc -A -o " + discoverJSONPath
	if last := f.calls[len(f.calls)-1]; last != want {
		t.Fatalf("call = %q, want %q", last, want)
	}
}

// TestParseReady checks the set of ready Services
func TestParseReady(t *testing.T) {
	out := "shop|web|true,false,\nshop|web|false,\nshop|db|false,false,\n" +
		"shop|none|\n|web|true,\nshop||true,\nmon|prom|false,true,\n\nbare\n"
	want := []string{"mon/prom", "shop/web"}
	var got []string
	for key := range parseReady(out) {
		got = append(got, key)
	}
	sort.Strings(got)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ready = %v, want %v", got, want)
	}
}

// TestReadyServicesFailure checks that a failing call is reported apart from an
// empty answer, whatever the way it fails
func TestReadyServicesFailure(t *testing.T) {
	cases := map[string]reply{
		"status": {match: "endpointslices", status: 1, stdout: "shop|web|true,\n"},
		"error":  {match: "endpointslices", err: errors.New("cannot start")},
	}
	for name, r := range cases {
		f := &fakeRunner{replies: []reply{r, {match: "config get-contexts"}}}
		if got, err := readyServices(f); !errors.Is(err, errEndpointsUnreadable) || got != nil {
			t.Errorf("%s: got %v, %v", name, got, err)
		}
	}
	f := &fakeRunner{replies: []reply{{match: "endpointslices"}, {match: "config get-contexts"}}}
	got, err := readyServices(f)
	if err != nil || len(got) != 0 {
		t.Fatalf("empty answer: got %v, %v", got, err)
	}
	f = &fakeRunner{replies: []reply{{match: "endpointslices", stdout: "shop|web|true,\n"}, {match: "config get-contexts"}}}
	if got, err := readyServices(f); err != nil || !got["shop/web"] {
		t.Fatalf("got %v, %v", got, err)
	}
	if last := f.calls[len(f.calls)-1]; last != "get endpointslices -A -o "+readyJSONPath {
		t.Fatalf("call = %q", last)
	}
}

// takenOutside returns a taken function that finds free only the ports from lo
// to hi, to drive newLocalPort without any real port
func takenOutside(lo, hi int) func(int) bool {
	return func(p int) bool { return p < lo || p > hi }
}

// TestNewLocalPort checks the choice of the local port, with its bounds
func TestNewLocalPort(t *testing.T) {
	cases := []struct {
		name       string
		port       int
		used       []int
		free       func(int) bool
		want       int
		wantFailed bool
	}{
		{"80 gives 8080", 80, nil, takenOutside(1, 65535), 8080, false},
		{"5432 stays", 5432, nil, takenOutside(1, 65535), 5432, false},
		{"1024 stays", 1024, nil, takenOutside(1, 65535), 1024, false},
		{"1023 moves", 1023, nil, takenOutside(1, 65535), 9023, false},
		{"taken port moves", 5432, nil, takenOutside(5433, 65535), 13432, false},
		{"used port moves", 5432, []int{5432}, takenOutside(1, 65535), 13432, false},
		{"8080 used gives 8081", 80, []int{8080}, takenOutside(1, 65535), 8081, false},
		{"8080 taken gives 8081", 80, nil, takenOutside(8081, 65535), 8081, false},
		{"65000 is kept", 57000, []int{57000}, takenOutside(1, 65535), 65000, false},
		{"65001 restarts at 20000", 57001, []int{57001}, takenOutside(1, 65535), 20000, false},
		{"candidate wraps after 65000", 56999, []int{56999, 64999, 65000}, takenOutside(20000, 20000), 20000, false},
		{"wrap skips ports above", 56999, []int{56999, 64999, 65000}, takenOutside(1, 65535), 20000, false},
		{"65001 is never used", 56999, []int{56999, 64999, 65000, 20000}, takenOutside(1, 65535), 20001, false},
		{"high port restarts", 65000, []int{65000}, takenOutside(1, 65535), 20000, false},
		{"far free port", 80, nil, takenOutside(20000, 20010), 20000, false},
		{"all taken", 80, nil, takenOutside(1, 0), 0, true},
		{"free port out of reach", 80, nil, takenOutside(65001, 65535), 0, true},
	}
	for _, c := range cases {
		got, err := newLocalPort(c.port, c.used, c.free)
		if (err != nil) != c.wantFailed || err != nil && !errors.Is(err, errNoFreePort) || got != c.want {
			t.Errorf("%s: newLocalPort = %d, %v; want %d, failed %v", c.name, got, err, c.want, c.wantFailed)
		}
	}
}

// TestNewLocalPortTries checks that exactly localTries candidates are tested
func TestNewLocalPortTries(t *testing.T) {
	tested := 0
	_, err := newLocalPort(80, nil, func(int) bool { tested++; return true })
	if !errors.Is(err, errNoFreePort) || tested != 60000 {
		t.Fatalf("tested %d candidates, err %v; want 60000", tested, err)
	}
}

// TestLocalPortFree checks that a used port and a taken port are both refused
func TestLocalPortFree(t *testing.T) {
	never := func(int) bool { return false }
	if !localPortFree(8080, []int{1, 2}, never) {
		t.Error("unused free port must be free")
	}
	if localPortFree(2, []int{1, 2}, never) {
		t.Error("used port must not be free")
	}
	if localPortFree(8080, nil, func(p int) bool { return p == 8080 }) {
		t.Error("taken port must not be free")
	}
}
