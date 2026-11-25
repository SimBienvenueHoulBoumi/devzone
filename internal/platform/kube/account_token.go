package kube

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// tokenJSONPath extracts the token and the RFC 3339 expiration timestamp of a
// TokenRequest response.
const tokenJSONPath = `jsonpath={.status.token}{"\n"}{.status.expirationTimestamp}`

// tokenValidity is the TokenRequest duration of the limited account token, in
// seconds (24 h).
const tokenValidity = 86400

// ErrTokenContextNotReachable reports that the limited account context cannot
// answer the auth check: the renewal is refused and the expiry file removed.
var ErrTokenContextNotReachable = MessageError{Text: "limited account context not reachable"}

// ErrTokenEmpty reports that the TokenRequest response carries no token.
var ErrTokenEmpty = MessageError{Text: "limited account token is empty"}

// Token renews the token of the limited account (TokenRequest of 24 h) and
// writes it into the devzone context of the account kubeconfig, then keeps the
// expiration timestamp of the TokenRequest response in the expiry file only
// once the context answers the auth check.
func (k Kube) Token(ctx context.Context, contextName string) error {
	conf, _, res, err := k.adminRun(ctx, contextName, "create", "token", accountServiceAccount,
		"-n", accountNamespace, "--duration="+accountDuration, "-o", tokenJSONPath)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("cannot renew token of %s", accountServiceAccount)
	}
	token, expires, err := tokenResponse(res.Stdout)
	if err != nil {
		return err
	}
	cluster, err := k.contextCluster(ctx, conf, contextName)
	if err != nil {
		return err
	}
	server, err := k.clusterServer(ctx, conf, cluster)
	if err != nil {
		return err
	}
	caData := k.clusterCAData(ctx, conf, cluster)
	caFile := k.clusterCAFile(ctx, conf, cluster)
	tls := k.clusterTLS(ctx, conf, cluster)
	entry := []string{"--server=" + server}
	if caFile != "" {
		entry = append(entry, "--certificate-authority="+caFile, "--embed-certs=true")
	}
	if tls != "" {
		entry = append(entry, "--tls-server-name="+tls)
	}
	setArgs := append([]string{"config", "set-cluster", cluster}, entry...)
	res, err = k.Run(ctx, accountKubeconfigPath(), setArgs...)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("cannot set cluster %s", cluster)
	}
	if caData != "" {
		res, err = k.Run(ctx, accountKubeconfigPath(), "config", "set",
			"clusters."+cluster+".certificate-authority-data", caData)
		if err != nil {
			return err
		}
		if res.Code != 0 {
			return fmt.Errorf("cannot set certificate authority of cluster %s", cluster)
		}
	}
	res, err = k.Run(ctx, accountKubeconfigPath(), "config", "set-credentials", accountServiceAccount, "--token", token)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("cannot set credentials %s", accountServiceAccount)
	}
	res, err = k.Run(ctx, accountKubeconfigPath(), "config", "set-context", accountContextName,
		"--cluster", cluster, "--user", accountServiceAccount)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("cannot set context %s", accountContextName)
	}
	answer, err := k.Run(ctx, accountKubeconfigPath(), "--context", accountContextName, "auth", "can-i",
		"get", "pods", "-n", accountNamespace)
	if err != nil {
		return err
	}
	switch strings.TrimSpace(string(answer.Stdout)) {
	case "yes", "no":
	default:
		_ = os.Remove(tokenExpiryPath())
		return ErrTokenContextNotReachable
	}
	expiry := time.Now().Unix() + tokenValidity
	if epoch, ok := k.ExpiryEpoch(expires); ok {
		expiry = epoch
	}
	if dir := filepath.Dir(tokenExpiryPath()); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if err := os.WriteFile(tokenExpiryPath(), []byte(fmt.Sprintf("%d\n", expiry)), 0o600); err != nil {
		return err
	}
	return os.Chmod(tokenExpiryPath(), 0o600)
}

// tokenResponse splits the output of the TokenRequest jsonpath: the token
// first, the RFC 3339 expiration timestamp second.
func tokenResponse(out []byte) (string, string, error) {
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	token := strings.TrimSpace(lines[0])
	expires := ""
	if len(lines) > 1 {
		expires = strings.TrimSpace(lines[1])
	}
	if token == "" {
		return "", "", ErrTokenEmpty
	}
	return token, expires, nil
}

// contextCluster returns the name of the cluster of a context of the
// kubeconfig conf.
func (k Kube) contextCluster(ctx context.Context, conf string, contextName string) (string, error) {
	res, err := k.Run(ctx, conf, "config", "view", "-o",
		fmt.Sprintf(`{.contexts[?(@.name=="%s")].context.cluster}`, contextName))
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return "", fmt.Errorf("cannot read context %s of %s", contextName, conf)
	}
	cluster := strings.TrimSpace(string(res.Stdout))
	if cluster == "" {
		return "", MessageError{Text: fmt.Sprintf("cluster of context %s not found in %s", contextName, conf)}
	}
	return cluster, nil
}

// clusterServer returns the server of a cluster of the kubeconfig conf.
func (k Kube) clusterServer(ctx context.Context, conf string, cluster string) (string, error) {
	res, err := k.Run(ctx, conf, "config", "view", "-o",
		fmt.Sprintf(`{.clusters[?(@.name=="%s")].cluster.server}`, cluster))
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return "", fmt.Errorf("cannot read cluster %s of %s", cluster, conf)
	}
	server := strings.TrimSpace(string(res.Stdout))
	if server == "" {
		return "", MessageError{Text: fmt.Sprintf("server of cluster %s not found in %s", cluster, conf)}
	}
	return server, nil
}

// clusterCAData returns the base64 certificate authority data of a cluster of
// the kubeconfig conf; empty when the cluster has no authority or when the read
// fails (the context then keeps the cluster entry without authority).
func (k Kube) clusterCAData(ctx context.Context, conf string, cluster string) string {
	res, err := k.Run(ctx, conf, "config", "view", "--raw", "-o",
		fmt.Sprintf(`{.clusters[?(@.name=="%s")].cluster.certificate-authority-data}`, cluster))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// clusterCAFile returns the path of the certificate authority file of a
// cluster of the kubeconfig conf; empty when the cluster has none.
func (k Kube) clusterCAFile(ctx context.Context, conf string, cluster string) string {
	res, err := k.Run(ctx, conf, "config", "view", "-o",
		fmt.Sprintf(`{.clusters[?(@.name=="%s")].cluster.certificate-authority}`, cluster))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// clusterTLS returns the tls-server-name of a cluster of the kubeconfig conf;
// empty when the cluster has none.
func (k Kube) clusterTLS(ctx context.Context, conf string, cluster string) string {
	res, err := k.Run(ctx, conf, "config", "view", "-o",
		fmt.Sprintf(`{.clusters[?(@.name=="%s")].cluster.tls-server-name}`, cluster))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}
