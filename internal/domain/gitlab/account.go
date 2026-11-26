package gitlab

import (
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Constants of the limited account (#430): the ServiceAccount of the
// devzone-system namespace and the label of the devzone namespaces.
const (
	accountNS    = "devzone-system"
	accountSA    = "devzone-agent"
	clusterLabel = "app.kubernetes.io/managed-by=devzone"
	// netpolYaml is the isolating NetworkPolicy applied to the namespaces of
	// the instance (isolation.sh namespace_isolate).
	netpolYaml = `apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devzone-meme-namespace
  labels:
    app.kubernetes.io/managed-by: devzone
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
`
)

// kubectlAdminWithStdin runs kubectl with the administrator context and
// options (Stdin of exec.Opts is added to the environment by the runner).
func (r *run) kubectlAdminWithStdin(args []string, stdin string) (exec.Result, error) {
	ctx := r.accountContext()
	all := append([]string{"--kubeconfig=" + r.adminKubeconfig(ctx), "--context", ctx}, args...)
	return r.runner().Run(r.ctx, "kubectl", all, exec.Opts{Stdin: strings.NewReader(stdin)})
}

// kubectlAdminYAML runs kubectl with the administrator context and returns
// the stdout of create commands (the stdin variant with "").
func (r *run) kubectlAdminYAML(args []string) string {
	res, err := r.kubectlAdmin(args)
	if err != nil {
		return ""
	}
	return string(res.Stdout)
}

// accountSetup sets up the devzone-system namespace and the devzone-agent
// ServiceAccount of the instance (kube-account.sh account_setup).
func (r *run) accountSetup() {
	_, _ = r.kubectlAdminWithStdin([]string{"apply", "-f", "-"},
		r.kubectlAdminYAML([]string{"create", "namespace", accountNS, "--dry-run=client", "-o", "yaml"}))
	_, _ = r.kubectlAdminWithStdin([]string{"apply", "-f", "-"},
		r.kubectlAdminYAML([]string{"create", "-n", accountNS, "serviceaccount", accountSA, "--dry-run=client", "-o", "yaml"}))
}

// accountNamespace creates the namespace ns as administrator, labels it and
// allows the account (kube-account.sh account_namespace).
func (r *run) accountNamespace(ctx, ns string) {
	_, _ = r.kubectlAdminWithStdin([]string{"apply", "-f", "-"},
		r.kubectlAdminYAML([]string{"create", "namespace", ns, "--dry-run=client", "-o", "yaml"}))
	_, _ = r.kubectlAdmin([]string{"label", "namespace", ns, clusterLabel, "--overwrite"})
	r.accountAllow(ns)
}

// accountAllow binds the ServiceAccount to the edit ClusterRole in ns
// (kube-account.sh account_allow); the setup of the account comes first.
func (r *run) accountAllow(ns string) {
	r.accountSetup()
	_, _ = r.kubectlAdminWithStdin([]string{"apply", "-f", "-"},
		r.kubectlAdminYAML([]string{"create", "-n", ns, "rolebinding", accountSA,
			"--clusterrole=edit", "--serviceaccount=" + accountNS + ":" + accountSA,
			"--dry-run=client", "-o", "yaml"}))
}

// namespacePrepare creates the namespace of the instance and the isolation
// (installation.sh gitlab_namespace_prepare).
func (r *run) namespacePrepare() {
	r.accountNamespace(r.accountContext(), r.namespace())
	r.namespaceIsolate(r.namespace())
}

// namespaceIsolate sets the isolating NetworkPolicy of the namespace
// (isolation.sh namespace_isolate): only the pods of the same namespace can
// reach the services.
func (r *run) namespaceIsolate(ns string) {
	_, _ = r.kubectlDevzoneWithStdin([]string{"apply", "-f", "-"}, netpolYaml)
}

// kubectlDevzoneWithStdin runs kubectl on the devzone context with options.
func (r *run) kubectlDevzoneWithStdin(args []string, stdin string) (exec.Result, error) {
	all := append([]string{"--context", "devzone"}, args...)
	return r.runner().Run(r.ctx, "kubectl", all, exec.Opts{Stdin: strings.NewReader(stdin)})
}
