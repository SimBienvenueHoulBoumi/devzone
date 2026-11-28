package kube

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// DevzoneContextSet points the devzone context at the context named ctx, so
// that the services context installs on the chosen services cluster (#396).
func (k Kube) DevzoneContextSet(ctx context.Context, name string) bool {
	if ctx == nil {
		ctx = context.Background()
	}
	if name == "" {
		return false
	}
	clusterQuery := fmt.Sprintf(`{.contexts[?(@.name==%q)].context.cluster}`, name)
	userQuery := fmt.Sprintf(`{.contexts[?(@.name==%q)].context.user}`, name)
	clusterRes, err := k.runner().Run(ctx, "kubectl", []string{"config", "view", "-o", clusterQuery}, exec.Opts{})
	if err != nil || clusterRes.Code != 0 {
		return false
	}
	cluster := strings.TrimSpace(string(clusterRes.Stdout))
	if cluster == "" {
		return false
	}
	userRes, err := k.runner().Run(ctx, "kubectl", []string{"config", "view", "-o", userQuery}, exec.Opts{})
	if err != nil || userRes.Code != 0 {
		return false
	}
	user := strings.TrimSpace(string(userRes.Stdout))
	res, err := k.runner().Run(ctx, "kubectl", []string{
		"config", "set-context", "devzone", "--cluster=" + cluster, "--user=" + user}, exec.Opts{})
	return err == nil && res.Code == 0
}

// ClusterReachable reports whether the API server of ctx answers.
func (k Kube) ClusterReachable(ctx context.Context, name string) bool {
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := k.runner().Run(ctx, "kubectl",
		[]string{"--context", name, "--request-timeout=3s", "get", "--raw", "/readyz"}, exec.Opts{})
	return err == nil && res.Code == 0
}

// ClusterPrepare creates the dedicated kind cluster when needed and checks a
// chosen host cluster. It prints the same lines as cluster_prepare of cluster.sh.
func (k Kube) ClusterPrepare(ctx context.Context, name string, out, errOut io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	dedicated := "kind-devzone" + instanceSuffix()
	if name == dedicated {
		res, err := k.runner().Run(ctx, "kind", []string{"get", "clusters"}, exec.Opts{})
		if err != nil || res.Code != 0 || !hasLine(string(res.Stdout), clusterName()) {
			fmt.Fprintln(out, "▶ Creating the kind devzone cluster (about 1 min)…")
			if code, err := k.kindCreate(ctx); err != nil || code != 0 {
				fmt.Fprintln(out, "▶ Retrying the kind cluster creation…")
				_, _ = k.runner().Run(ctx, "kind", []string{"delete", "cluster", "--name", clusterName()}, exec.Opts{})
				code, err = k.kindCreate(ctx)
				if err != nil || code != 0 {
					return err
				}
			}
		}
	} else if !k.ClusterReachable(ctx, name) {
		fmt.Fprintf(errOut, "devzone : cluster %s unreachable (kubernetes module enabled? cluster started?)\n", name)
		return fmt.Errorf("cluster %s unreachable", name)
	}
	if !k.DevzoneContextSet(ctx, name) {
		fmt.Fprintf(errOut, "devzone : devzone context not set on %s\n", name)
	}
	return nil
}

// kindCreate creates a kind cluster without changing the working context of kubectl.
func (k Kube) kindCreate(ctx context.Context) (int, error) {
	previousRes, _ := k.runner().Run(ctx, "kubectl", []string{"config", "current-context"}, exec.Opts{})
	previous := strings.TrimSpace(string(previousRes.Stdout))
	res, err := k.runner().Run(ctx, "kind", []string{"create", "cluster", "--name", clusterName(), "--wait", "120s"}, exec.Opts{})
	if err == nil && res.Code != 0 {
		err = &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	if previous != "" {
		_, _ = k.runner().Run(ctx, "kubectl", []string{"config", "use-context", previous}, exec.Opts{})
	} else {
		conf := filepath.Join(home(), ".kube", "config")
		_, _ = k.runner().Run(ctx, "kubectl", []string{"config", "unset", "current-context"},
			exec.Opts{Env: []string{"KUBECONFIG=" + conf}})
	}
	if err != nil {
		return 0, err
	}
	return res.Code, nil
}

// ClusterRelease deletes the dedicated kind cluster when no devzone namespace
// is left on it, as cluster_release of cluster.sh does.
func (k Kube) ClusterRelease(ctx context.Context, name string, out, errOut io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if name != "kind-devzone"+instanceSuffix() {
		return nil
	}
	res, err := k.runner().Run(ctx, "kind", []string{"get", "clusters"}, exec.Opts{})
	if err != nil || res.Code != 0 || !hasLine(string(res.Stdout), clusterName()) {
		return nil
	}
	left, err := k.AccountAdmin(ctx, name, "get", "namespaces", "-l", clusterLabel(), "-o", "name")
	if err != nil || left.Code != 0 || strings.TrimSpace(string(left.Stdout)) != "" {
		return nil
	}
	_, _ = k.runner().Run(ctx, "kind", []string{"delete", "cluster", "--name", clusterName()}, exec.Opts{})
	fmt.Fprintln(out, "▶ kind devzone cluster removed (no service left).")
	return nil
}

// instanceSuffix returns the suffix of the dedicated cluster for this instance.
func instanceSuffix() string {
	name := os.Getenv("DEVZONE_INSTANCE")
	if name == "" || name == "devzone" {
		return ""
	}
	return "-" + name
}

// clusterName is the name of the dedicated kind cluster node.
func clusterName() string { return "devzone" + instanceSuffix() }

// clusterLabel is the label set on every namespace created by devzone.
func clusterLabel() string { return "app.kubernetes.io/managed-by=devzone" }

// hasLine reports whether text holds line as a whole line.
func hasLine(text, line string) bool {
	for _, candidate := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if strings.TrimSpace(candidate) == line {
			return true
		}
	}
	return false
}
