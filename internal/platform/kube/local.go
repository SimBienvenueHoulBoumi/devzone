package kube

import (
	"context"
	"fmt"
	"strings"
)

// IsLocal reports whether the services context is a local cluster, by its name
// or by the loopback host of its API server.
func IsLocal(contextName string) bool {
	return Kube{}.IsLocal(contextName)
}

// IsLocal reports whether contextName is local, with the runner of this instance.
func (k Kube) IsLocal(contextName string) bool {
	if nameIsLocal(contextName) {
		return true
	}
	conf := k.AdminKubeconfig(contextName)
	query := fmt.Sprintf("jsonpath={.contexts[?(@.name==%q)].context.cluster}", contextName)
	res, err := k.Run(context.Background(), conf, "config", "view", "-o", query)
	if err != nil || res.Code != 0 {
		return false
	}
	clusterName := strings.TrimSpace(string(res.Stdout))
	if clusterName == "" {
		return false
	}
	query = fmt.Sprintf("jsonpath={.clusters[?(@.name==%q)].cluster.server}", clusterName)
	res, err = k.Run(context.Background(), conf, "config", "view", "-o", query)
	if err != nil || res.Code != 0 {
		return false
	}
	return serverIsLocal(string(res.Stdout))
}

// nameIsLocal checks the context names that always designate a local cluster.
func nameIsLocal(contextName string) bool {
	if strings.HasPrefix(contextName, "kind-") {
		return true
	}
	switch contextName {
	case "docker-desktop", "rancher-desktop", "orbstack", "minikube":
		return true
	}
	return false
}

// serverIsLocal extracts the host of a kubeconfig server URL and checks whether
// it is a loopback address or a kind control-plane endpoint.
func serverIsLocal(server string) bool {
	host := server
	if i := strings.Index(host, "://"); i >= 0 {
		host = host[i+3:]
	}
	if i := strings.IndexByte(host, '/'); i >= 0 {
		host = host[:i]
	}
	if strings.HasPrefix(host, "[") {
		if i := strings.IndexByte(host, ']'); i >= 0 {
			host = host[1:i]
		}
	} else if i := strings.IndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	switch host {
	case "127.0.0.1", "localhost", "::1", "host.docker.internal":
		return true
	}
	return strings.HasSuffix(host, "-control-plane")
}
