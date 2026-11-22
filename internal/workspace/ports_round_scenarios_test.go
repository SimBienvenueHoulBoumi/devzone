package workspace

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func relayedLine(port int) string {
	return "→ port " + strconv.Itoa(port) + " relayed on 127.0.0.1\n"
}

func takenLine(port int) string {
	return "⚠ port " + strconv.Itoa(port) + " already in use on the workstation, not relayed\n"
}

func TestRoundMatchesBashModules(t *testing.T) {
	requirePortsFree(t, 5432, 3306)
	p := freePorts(t, 2)
	pair := newRoundPair(t)
	sc := scenario{contexts: "minikube\ndevzone\n", modules: "postgres=on\nmysql=true\n", pgadmin: strconv.Itoa(p[0]),
		argocd: "443", argoPort: strconv.Itoa(p[1])}
	out, _ := pair.step(sc, appsMax)
	if want := relayedLine(5432) + relayedLine(p[0]) + relayedLine(3306) + relayedLine(p[1]); out != want {
		t.Fatalf("Go printed %q, want %q", out, want)
	}
	if out, _ = pair.step(sc, appsMax); out != "" || liveRelays(pair.goDir) != 4 {
		t.Fatalf("second round: %q, %d live", out, liveRelays(pair.goDir))
	}
	sc.modules = "argocd=off\nmysql=on\n"
	pair.step(sc, appsMax)
	if liveRelays(pair.goDir) != 1 {
		t.Fatalf("module switched off: %d live relays, want 1", liveRelays(pair.goDir))
	}
	pair.finish()
}

func TestRoundMatchesBashPodPorts(t *testing.T) {
	p := freePorts(t, 3)
	pair := newRoundPair(t)
	sc := scenario{argocd: "443", argoPort: strconv.Itoa(p[0]),
		ss: listenLine(p[2]) + listenLine(p[1]) + listenLine(p[1]) + listenLine(p[0]) + listenLine(2475) + listenLine(1234) +
			listenLine(22) + "LISTEN 0 4096 [::]:" + strconv.Itoa(p[2]) + " [::]:*\nLISTEN 0 4096 x y\n",
		// an application on a port the pod already listens on must get another local port
		svc: svcLine("shop", "web", p[2]), ready: readyLine("shop", "web")}
	out, _ := pair.step(sc, appsMax)
	if want := relayedLine(p[0]) + relayedLine(p[1]) + relayedLine(p[2]); !strings.HasPrefix(out, want) || strings.Count(out, "relayed") != 4 {
		t.Fatalf("Go printed %q, want %q first (module port first, no duplicate), then the application", out, want)
	}
	if got := readAll(filepath.Join(pair.goDir, "apps", "shop.web."+strconv.Itoa(p[2]))); got == strconv.Itoa(p[2]) || liveRelays(pair.goDir) != 4 {
		t.Fatalf("application kept the port of the pod (%s), %d live relays", got, liveRelays(pair.goDir))
	}
	pair.finish()
}

func TestRoundMatchesBashApplications(t *testing.T) {
	p := freePorts(t, 6)
	pair := newRoundPair(t)
	sc := scenario{
		modules: "excluded_ports=" + strconv.Itoa(p[3]) + "\n",
		svc: svcLine("shop", "web", p[0]) + svcLine("shop", "db", p[1]) + svcLine("shop", "http", 80) + svcLine("shop", "nopod", p[2]) +
			svcLine("shop", "kept", p[3]) + svcLine("kube-system", "dns", 53) + "shop|head|None|ClusterIP||9/TCP,\n",
		ready: readyLine("shop", "web") + readyLine("shop", "db") + readyLine("shop", "http") + readyLine("shop", "kept") + "shop|nopod|false,\n",
		ss:    listenLine(p[4]),
	}
	out, errOut := pair.step(sc, appsMax)
	if !hasAll(out, relayedLine(p[0]), relayedLine(p[1]), relayedLine(p[4])) || strings.Contains(out, relayedLine(p[2])) || errOut != "" {
		t.Fatalf("out %q err %q", out, errOut)
	}
	if _, err := os.Stat(filepath.Join(pair.goDir, "no-ready-pod", "shop.nopod."+strconv.Itoa(p[2]))); err != nil {
		t.Fatal("no marker for the Service without ready pod")
	}
	if out, _ = pair.step(sc, appsMax); out != "" {
		t.Fatalf("second round printed %q", out)
	}
	sc.ready += readyLine("shop", "nopod")
	if out, _ = pair.step(sc, appsMax); out != relayedLine(p[2]) {
		t.Fatalf("service became ready: %q", out)
	}
	pair.finish()
}

func TestRoundMatchesBashTakenPortWarnsOnce(t *testing.T) {
	p := freePorts(t, 3)
	pair := newRoundPair(t)
	releasePod := holdPort(t, p[0])
	holdPort(t, p[1])
	sc := scenario{ss: listenLine(p[0]), svc: svcLine("shop", "web", p[1]) + svcLine("shop", "api", p[2]),
		ready: readyLine("shop", "web") + readyLine("shop", "api")}
	out, _ := pair.step(sc, appsMax)
	if !strings.HasPrefix(out, takenLine(p[0])) || strings.Count(out, "already in use") != 1 || !strings.Contains(out, relayedLine(p[2])) {
		t.Fatalf("first round %q", out)
	}
	if out, _ = pair.step(sc, appsMax); out != "" {
		t.Fatalf("warning repeated: %q", out)
	}
	releasePod()
	if out, _ = pair.step(sc, appsMax); out != relayedLine(p[0]) {
		t.Fatalf("after release %q", out)
	}
	if _, err := os.Stat(filepath.Join(pair.goDir, "taken", strconv.Itoa(p[0]))); err == nil {
		t.Fatal("marker kept after the port was relayed")
	}
	pair.finish()
}

func TestRoundMatchesBashCap(t *testing.T) {
	for _, max := range []int{3, appsMax} {
		t.Run(strconv.Itoa(max), func(t *testing.T) {
			p := freePorts(t, max+2)
			pair := newRoundPair(t)
			sc := scenario{}
			for i, port := range p {
				name := "s" + strconv.Itoa(i)
				sc.svc += svcLine("shop", name, port)
				sc.ready += readyLine("shop", name)
			}
			out, errOut := pair.step(sc, max)
			if strings.Count(out, "relayed") != max || strings.Count(errOut, "cap of "+strconv.Itoa(max)) != 2 {
				t.Fatalf("out %q err %q", out, errOut)
			}
			if _, errOut = pair.step(sc, max); errOut != "" || liveRelays(pair.goDir) != max {
				t.Fatalf("second round: %q, %d live", errOut, liveRelays(pair.goDir))
			}
			pair.finish()
		})
	}
}

func TestRoundMatchesBashLiveRelayKept(t *testing.T) {
	p := freePorts(t, 1)
	pair := newRoundPair(t)
	pair.seedLive(p[0])
	out, _ := pair.step(scenario{ss: listenLine(p[0])}, appsMax)
	if out != "" || !strings.Contains(pair.dump(pair.goDir), "relays/"+strconv.Itoa(p[0])+" = \"seeded") {
		t.Fatalf("live relay touched: %q\n%s", out, pair.dump(pair.goDir))
	}
	pair.finish()
	if strings.Contains(readAll(pair.goLog), "port-forward") {
		t.Fatal("kubectl port-forward started for a live relay")
	}
}

func TestRoundMatchesBashGoneServiceRemoved(t *testing.T) {
	p := freePorts(t, 3)
	pair := newRoundPair(t)
	sc := scenario{ss: listenLine(p[0]), svc: svcLine("shop", "web", p[1]), ready: readyLine("shop", "web")}
	pair.step(sc, appsMax)
	pair.seedLive(p[2])
	if liveRelays(pair.goDir) != 3 {
		t.Fatalf("%d live relays before", liveRelays(pair.goDir))
	}
	pair.step(scenario{}, appsMax)
	if d := pair.dump(pair.goDir); strings.Contains(d, " = ") || liveRelays(pair.goDir) != 0 {
		t.Fatalf("state kept after services went away:\n%s", d)
	}
	pair.finish()
}

func TestRoundMatchesBashUnreadableEndpoints(t *testing.T) {
	p := freePorts(t, 1)
	pair := newRoundPair(t)
	sc := scenario{svc: svcLine("shop", "web", p[0]), ready: readyLine("shop", "web"), readyFail: true}
	out, errOut := pair.step(sc, appsMax)
	if out != relayedLine(p[0]) || errOut != "⚠ endpointslices unreadable, ready pods not checked\n" {
		t.Fatalf("out %q err %q", out, errOut)
	}
	if _, errOut = pair.step(sc, appsMax); errOut != "" {
		t.Fatalf("warning repeated: %q", errOut)
	}
	sc.readyFail = false
	pair.step(sc, appsMax)
	sc.readyFail = true
	if _, errOut = pair.step(sc, appsMax); errOut == "" {
		t.Fatal("no new warning after a good read")
	}
	pair.finish()
}
