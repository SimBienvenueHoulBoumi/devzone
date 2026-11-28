package workspace

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// goRound runs one round of the Go code on dir with the fake kubectl; the ports
// of taken are in use on the workstation, max caps the application relays.
func (h *roundHarness) goRound(dir string, taken map[int]bool, max int) (string, string) {
	var out, errOut bytes.Buffer
	env := roundEnv{
		runner: ExecRunner{}, dir: dir, modules: h.modules, taken: func(p int) bool { return taken[p] },
		start: startDetached, max: max, out: &out, errOut: &errOut,
	}
	env.round()
	return out.String(), errOut.String()
}

// relayPids returns the pid written in each file of dir/relays, by port.
func relayPids(dir string) map[string]int {
	pids := map[string]int{}
	for _, name := range stateNames(filepath.Join(dir, "relays")) {
		pids[name] = readPid(filepath.Join(dir, "relays", name))
	}
	return pids
}

// waitFor polls cond for three seconds: processes start and stop after the round returns.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 300; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}

// logHas tells whether the fake kubectl log holds all the lines.
func logHas(log string, lines ...string) bool {
	data, _ := os.ReadFile(log)
	for _, l := range lines {
		if !strings.Contains(string(data), l+"\n") {
			return false
		}
	}
	return true
}

func TestRoundRelaysEverything(t *testing.T) {
	h := newRoundHarness(t)
	p := freePorts(t, 5)
	sc := scenario{
		contexts: fexec.ContextName() + "\n", modules: "postgres=on\nmysql=on\n", pgadmin: strconv.Itoa(p[1]), argocd: "443", argoPort: strconv.Itoa(p[0]),
		ss:  listenLine(p[2]) + listenLine(p[0]) + listenLine(2475) + listenLine(80),
		svc: svcLine("shop", "web", p[3]) + svcLine("shop", "off", p[4]), ready: readyLine("shop", "web"),
	}
	log := filepath.Join(h.dir, "kubectl.log")
	h.use(sc, log)
	dir := h.stateDir("state")
	out, errOut := h.goRound(dir, nil, appsMax)
	want := ""
	for _, port := range []int{5432, p[1], 3306, p[0], p[2], p[3]} {
		want += "→ port " + strconv.Itoa(port) + " relayed on 127.0.0.1\n"
	}
	if out != want || errOut != "" {
		t.Fatalf("out %q err %q, want %q", out, errOut, want)
	}
	if n := liveRelays(dir); n != 6 {
		t.Fatalf("%d live relays, want 6", n)
	}
	format := func(ns, target string, local, remote int) string {
		return "--context " + fexec.ContextName() + " --namespace " + ns + " port-forward --address 127.0.0.1 " + target + " " +
			strconv.Itoa(local) + ":" + strconv.Itoa(remote)
	}
	waitFor(t, "port-forward calls", func() bool {
		return logHas(log,
			format("devzone-postgres", "svc/postgres", 5432, 5432),
			format("devzone-argocd", "svc/argocd-server", p[0], 443),
			format("devzone-workspace", "pod/devzone-workspace-0", p[2], p[2]),
			format("shop", "svc/web", p[3], p[3]))
	})
	if logHas(log, format("shop", "svc/off", p[4], p[4])) {
		t.Fatal("a Service without ready pod was relayed")
	}
	before := relayPids(dir)
	if out, errOut = h.goRound(dir, nil, appsMax); out != "" || errOut != "" {
		t.Fatalf("second round printed %q %q", out, errOut)
	}
	for port, pid := range relayPids(dir) {
		if before[port] != pid {
			t.Fatalf("relay %s restarted", port)
		}
	}
}

func TestRoundTakenPortWarnsOnce(t *testing.T) {
	h := newRoundHarness(t)
	port := freePorts(t, 1)[0]
	h.use(scenario{ss: listenLine(port)}, filepath.Join(h.dir, "k.log"))
	dir := h.stateDir("state")
	taken := map[int]bool{port: true}
	warning := "⚠ port " + strconv.Itoa(port) + " already in use on the workstation, not relayed\n"
	if out, _ := h.goRound(dir, taken, appsMax); out != warning {
		t.Fatalf("first round: %q", out)
	}
	marker := filepath.Join(dir, "taken", strconv.Itoa(port))
	if !present(marker) || liveRelays(dir) != 0 {
		t.Fatal("marker missing or relay started on a taken port")
	}
	if out, _ := h.goRound(dir, taken, appsMax); out != "" {
		t.Fatalf("warning repeated: %q", out)
	}
	delete(taken, port)
	if out, _ := h.goRound(dir, taken, appsMax); out != "→ port "+strconv.Itoa(port)+" relayed on 127.0.0.1\n" {
		t.Fatalf("after release: %q", out)
	}
	if present(marker) || liveRelays(dir) != 1 {
		t.Fatal("marker kept or relay missing once the port is free")
	}
}

func TestRoundRestartsDeadRelay(t *testing.T) {
	h := newRoundHarness(t)
	port := freePorts(t, 1)[0]
	h.use(scenario{ss: listenLine(port)}, filepath.Join(h.dir, "k.log"))
	dir := h.stateDir("state")
	h.goRound(dir, nil, appsMax)
	name := strconv.Itoa(port)
	pid := relayPids(dir)[name]
	if pid <= 0 {
		t.Fatal("no relay pid recorded")
	}
	terminate(pid)
	waitFor(t, "relay to disappear", func() bool { return !alive(pid) })
	if out, _ := h.goRound(dir, nil, appsMax); out != "→ port "+name+" relayed on 127.0.0.1\n" {
		t.Fatalf("dead relay not restarted: %q", out)
	}
	if relayPids(dir)[name] == pid || liveRelays(dir) != 1 {
		t.Fatal("pid unchanged or no live relay")
	}
}

func TestRoundKeepsLiveRelay(t *testing.T) {
	h := newRoundHarness(t)
	port := freePorts(t, 1)[0]
	log := filepath.Join(h.dir, "k.log")
	h.use(scenario{ss: listenLine(port)}, log)
	dir := h.stateDir("state")
	pid := h.seedRelay(dir, port)
	if out, errOut := h.goRound(dir, nil, appsMax); out != "" || errOut != "" {
		t.Fatalf("printed %q %q", out, errOut)
	}
	time.Sleep(100 * time.Millisecond)
	if relayPids(dir)[strconv.Itoa(port)] != pid || strings.Contains(readAll(log), "port-forward") {
		t.Fatal("a live relay was started again")
	}
}

func TestRoundRemovesGoneState(t *testing.T) {
	h := newRoundHarness(t)
	p := freePorts(t, 3)
	log := filepath.Join(h.dir, "k.log")
	h.use(scenario{ss: listenLine(p[0]), svc: svcLine("shop", "web", p[1]), ready: readyLine("shop", "web")}, log)
	dir := h.stateDir("state")
	if err := os.MkdirAll(filepath.Join(dir, "taken"), 0o755); err != nil {
		t.Fatal(err)
	}
	touch(filepath.Join(dir, "taken", strconv.Itoa(p[2])))
	h.goRound(dir, nil, appsMax)
	if liveRelays(dir) != 2 || !present(filepath.Join(dir, "apps", "shop.web."+strconv.Itoa(p[1]))) {
		t.Fatal("setup failed")
	}
	pids := relayPids(dir)
	h.use(scenario{}, log)
	h.goRound(dir, nil, appsMax)
	for _, sub := range []string{"relays", "taken", "apps", "cap", "no-ready-pod"} {
		if names := stateNames(filepath.Join(dir, sub)); len(names) != 0 {
			t.Errorf("%s still holds %v", sub, names)
		}
	}
	for port, pid := range pids {
		waitFor(t, "relay "+port+" to stop", func() bool { return !liveProc(pid) })
	}
}

func TestRoundCapOfApplicationRelays(t *testing.T) {
	h := newRoundHarness(t)
	p := freePorts(t, appsMax+2)
	sc := scenario{}
	for i, port := range p {
		name := "s" + strconv.Itoa(i)
		sc.svc += svcLine("shop", name, port)
		sc.ready += readyLine("shop", name)
	}
	h.use(sc, filepath.Join(h.dir, "k.log"))
	dir := h.stateDir("state")
	out, errOut := h.goRound(dir, nil, appsMax)
	if n := strings.Count(out, "relayed"); n != appsMax || liveRelays(dir) != appsMax {
		t.Fatalf("%d relayed lines, %d live, want %d", n, liveRelays(dir), appsMax)
	}
	if want := "⚠ cap of 30 application relays reached, shop/s30:" + strconv.Itoa(p[30]) + " not relayed\n"; !strings.HasPrefix(errOut, want) || strings.Count(errOut, "\n") != 2 {
		t.Fatalf("warnings %q", errOut)
	}
	if _, errOut = h.goRound(dir, nil, appsMax); errOut != "" || len(stateNames(filepath.Join(dir, "cap"))) != 2 {
		t.Fatalf("second round %q cap %v", errOut, stateNames(filepath.Join(dir, "cap")))
	}
}

func TestRoundStartFailure(t *testing.T) {
	h := newRoundHarness(t)
	port := freePorts(t, 1)[0]
	h.use(scenario{ss: listenLine(port)}, filepath.Join(h.dir, "k.log"))
	dir := h.stateDir("state")
	var out, errOut bytes.Buffer
	env := roundEnv{
		runner: ExecRunner{}, dir: dir, modules: h.modules, taken: func(int) bool { return false },
		start: func(*exec.Cmd) (int, error) { return 0, errors.New("boom") }, max: appsMax, out: &out, errOut: &errOut,
	}
	env.round()
	if out.Len() != 0 || errOut.String() != "⚠ port "+strconv.Itoa(port)+" not relayed: boom\n" || present(filepath.Join(dir, "relays", strconv.Itoa(port))) {
		t.Fatalf("out %q err %q", out.String(), errOut.String())
	}
}

func TestPortsRoundUsesStateFolderAndModules(t *testing.T) {
	h := newRoundHarness(t)
	p := freePorts(t, 2)
	h.use(scenario{ss: listenLine(p[0]), svc: svcLine("shop", "web", p[1]), ready: readyLine("shop", "web")}, filepath.Join(h.dir, "k.log"))
	dir := h.stateDir("state")
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	t.Chdir(h.dir)
	var out, errOut bytes.Buffer
	if code := PortsRound(&out, &errOut); code != 0 || strings.Count(out.String(), "relayed") != 2 || liveRelays(dir) != 2 {
		t.Fatalf("code %d out %q err %q live %d", code, out.String(), errOut.String(), liveRelays(dir))
	}
}
