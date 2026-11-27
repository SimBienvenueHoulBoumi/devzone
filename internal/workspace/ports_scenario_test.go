package workspace

// scenario describes cluster, workstation and modules state for port watcher tests.
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

// fake returns a Runner that answers like the fake kubectl for this scenario.
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

// env returns environment variables that make the fake kubectl answer as the scenario.
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
