package workspace

import (
	"path/filepath"
	"strconv"
	"testing"
)

// TestRoundRelaysGitlabModule checks the relays the module gitlab asks for:
// the web service (8929→8181) and the SSH shell (2224→2224) of the GitLab
// instance, then their removal at the next round when the module is off.
func TestRoundRelaysGitlabModule(t *testing.T) {
	h := newRoundHarness(t)
	sc := scenario{contexts: "devzone\n", modules: "gitlab=on\n", ss: "", svc: "", ready: "", argocd: ""}
	log := filepath.Join(h.dir, "kubectl.log")
	h.use(sc, log)
	dir := h.stateDir("state")
	out, errOut := h.goRound(dir, nil, appsMax)
	want := relayedLine(8929) + relayedLine(2224)
	if out != want || errOut != "" {
		t.Fatalf("out %q err %q, want %q", out, errOut, want)
	}
	if n := liveRelays(dir); n != 2 {
		t.Fatalf("%d live relays, want 2", n)
	}
	format := func(ns, target string, local, remote int) string {
		return "--context devzone --namespace " + ns + " port-forward --address 127.0.0.1 " + target + " " +
			strconv.Itoa(local) + ":" + strconv.Itoa(remote)
	}
	waitFor(t, "port-forward calls", func() bool {
		return logHas(log,
			format("devzone-gitlab", "svc/gitlab-webservice-default", 8929, 8181),
			format("devzone-gitlab", "svc/gitlab-gitlab-shell", 2224, 2224))
	})
	if out, errOut = h.goRound(dir, nil, appsMax); out != "" || errOut != "" {
		t.Fatalf("second round printed %q %q", out, errOut)
	}
	h.use(scenario{contexts: "devzone\n", modules: "gitlab=off\n", ss: "", svc: "", ready: "", argocd: ""}, log)
	if out, errOut = h.goRound(dir, nil, appsMax); out != "" || errOut != "" {
		t.Fatalf("round after switching the module off printed %q %q", out, errOut)
	}
	if liveRelays(dir) != 0 {
		t.Fatalf("%d live relays after the module off, want 0", liveRelays(dir))
	}
}
