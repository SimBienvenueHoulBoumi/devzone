package gitlab

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// statusServer starts a local server standing in for the GitLab of the tests
// (testBaseURL): readiness answers 200, the group answers id 42, the pipeline
// answers success, everything else answers 200.
func statusServer(t testing.TB) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "pipelines/"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"status":"success","id":42,"web_url":"http://gitlab.localhost:8929/devzone/demo/-/pipelines/42"}`))
		case strings.Contains(r.URL.Path, "groups/devzone"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"id":42}`))
		case strings.Contains(r.URL.Path, "user/runners"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"token":"token-runner-secret"}`))
		default:
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"id":42}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// programMemory programs the answer of the nodes call of memoryClusterKi:
// one line per node "providerID|memory".
func (f *fixture) programMemory(lines string) {
	conf := kube.AdminKubeconfig("devzone-services")
	f.r.On("kubectl", []string{"--kubeconfig=" + conf, "--context", "devzone-services", "get", "nodes",
		"-o", "jsonpath={range .items[*]}{.spec.providerID}{\"|\"}{.status.allocatable.memory}{\"\\n\"}{end}"},
		exec.Result{Stdout: []byte(lines)})
}

// programCurrentContext programs the current context of the fake kubectl.
func (f *fixture) programCurrentContext(ctx string) {
	f.r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte(ctx)})
}

// programNamespacePrepare programs the calls of accountNamespace: the create
// namespace and the label of the instance, and the account setup of the run.
func (f *fixture) programNamespacePrepare(ns string) {
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig(ns), "--context", ns, "create", "namespace", ns,
		"--dry-run=client", "-o", "yaml"}, exec.Result{Stdout: []byte("kind: Namespace\nmetadata:\n  name: " + ns + "\n")})
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig(ns), "--context", ns, "apply", "-f", "-"}, exec.Result{})
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig(ns), "--context", ns, "label", "namespace", ns,
		clusterLabel, "--overwrite"}, exec.Result{})
	for _, args := range [][]string{
		{"create", "namespace", accountNS, "--dry-run=client", "-o", "yaml"},
		{"create", "-n", accountNS, "serviceaccount", accountSA, "--dry-run=client", "-o", "yaml"},
		{"create", "-n", ns, "rolebinding", accountSA, "--clusterrole=edit",
			"--serviceaccount=" + accountNS + ":" + accountSA, "--dry-run=client", "-o", "yaml"},
	} {
		all := append([]string{"--kubeconfig=" + kube.AdminKubeconfig(ns), "--context", ns}, args...)
		f.r.On("kubectl", all, exec.Result{Stdout: []byte("kind: X\n")})
	}
}

// programHelm programs the calls of helmPass: any helm call answers 0.
func (f *fixture) programHelm() {
	f.r.On("helm", nil, exec.Result{})
}

// programInstallFull programs the fake runner and the server for a full
// install happy path (as the fakes of the bats tests).
func (f *fixture) programInstallFull() {
	f.programCurrentContext("devzone-services")
	f.programMemory("16777216Ki\n")
	f.programNamespacePrepare("devzone-gitlab")
	f.programHelm()
	f.programSeed()
	srv := statusServer(f.tb)
	testBaseURL = srv.URL
	f.tb.Cleanup(func() { testBaseURL = "" })
}

// programSeed programs the calls of the seed: the root password of the
// initial secret, the toolbox pod, the root token through gitlab-rails
// runner, the Secret of the chart and the Rails secret of the cluster.
func (f *fixture) programSeed() {
	// Any other kubectl call of the seed (the apply of the runner Secret, the
	// Rails secret read) answers 0; specific answers below win over it.
	f.r.On("kubectl", nil, exec.Result{})
	f.programSeedBase()
	ns := "devzone-gitlab"
	f.r.On("kubectl", []string{"--context", "devzone", "-n", ns, "create", "secret", "generic",
		"gitlab-runner-secret", "--from-file=runner-token=" + f.secretsDir() + "/runner-token",
		"--from-literal=runner-registration-token=", "--dry-run=client", "-o", "yaml"},
		exec.Result{Stdout: []byte("apiVersion: v1\nkind: Secret\n")})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", ns,
		"gitlab-rails-secret", "-o", "json"}, exec.Result{Stdout: []byte(`{"kind":"Secret","metadata":{"name":"gitlab-rails-secret","namespace":"devzone-gitlab","resourceVersion":"123","uid":"abc"}}`)})
}

// programSeedBase programs the first calls of the seed: the root password of
// the initial secret, the toolbox pod and the root token through
// gitlab-rails runner.
func (f *fixture) programSeedBase() {
	ns := "devzone-gitlab"
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", ns,
		"gitlab-gitlab-initial-root-password", "-o", "jsonpath={.data.password}"},
		exec.Result{Stdout: []byte("cGFzc3dvcmQxMjM=")})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", ns, "-l", "app=toolbox",
		"-o", "jsonpath={.items[0].metadata.name}"}, exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.r.On("kubectl", []string{"--context", "devzone", "exec", "-i", "-n", ns, "gitlab-toolbox-1",
		"--", "gitlab-rails", "runner", "-"}, exec.Result{Stdout: []byte("token-root-secret\n")})
}

// TestInstallRefusedUnder8GiB checks that the install is refused when the
// allocatable memory of the services cluster is below 8 GiB (gitlab.bats).
func TestInstallRefusedUnder8GiB(t *testing.T) {
	f := newFixture(t)
	f.programCurrentContext("devzone-services")
	f.programMemory("4000000Ki\n")
	if code := f.run("install"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "8 GiB") {
		t.Fatalf("stderr = %q", f.errStr())
	}
}

// TestInstallServicesCluster checks the install in the services cluster:
// helm with the devzone context, the namespace labelled and isolated, the
// runner held back at 0 (gitlab-cluster.bats).
func TestInstallServicesCluster(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("upgrade --install gitlab") || !f.hasCall("--namespace devzone-gitlab") {
		t.Fatalf("helm calls missing in %v", f.calls())
	}
	if !f.hasCall("label namespace devzone-gitlab app.kubernetes.io/managed-by=devzone") {
		t.Fatalf("no namespace label call in %v", f.calls())
	}
	if !f.hasCall("--context devzone apply -f -") {
		t.Fatalf("no network isolation call in %v", f.calls())
	}
	if strings.Contains(f.callsJoined(), "create cluster") {
		t.Fatalf("a kind cluster was created")
	}
	if !strings.Contains(f.outStr(), "▶ Installation complete.") {
		t.Fatalf("output = %q", f.outStr())
	}
}

// callsJoined returns the recorded calls as one string.
func (f *fixture) callsJoined() string {
	var parts []string
	for _, c := range f.r.Calls() {
		parts = append(parts, c.Name+" "+strings.Join(c.Args, " "))
	}
	return strings.Join(parts, "\n")
}

// TestInstallChartsPinned checks the pins of the wrapper chart in the values
// (gitlab.bats): the web service on the ClusterIP with the ingress off, the
// runner pointed to the instance namespace and the HPAs at 1.
func TestInstallChartsPinned(t *testing.T) {
	values, err := os.ReadFile("../../../charts/devzone-gitlab/values.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"type: ClusterIP",
		"nginx-ingress:",
		"enabled: false",
		"GITLAB_PORT: \"8929\"",
	} {
		if !strings.Contains(string(values), want) {
			t.Errorf("values.yaml lacks %q", want)
		}
	}
	if strings.Contains(string(values), "NodePort") || strings.Contains(string(values), "LoadBalancer") || strings.Contains(string(values), "hostPort") {
		t.Errorf("values.yaml exposes the service")
	}
	// The runner is pointed at the instance namespace by --set of the install.
	f := newFixture(t)
	f.programCurrentContext("devzone-services")
	f.programMemory("16777216Ki\n")
	f.programHelm()
	f.programSeed()
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("--set gitlab-runner.gitlabUrl=http://gitlab-webservice-default.devzone-gitlab.svc:8181") {
		t.Fatalf("no webservice URL of the runner in %v", f.calls())
	}
}
