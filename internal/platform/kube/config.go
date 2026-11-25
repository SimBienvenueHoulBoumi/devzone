package kube

import (
	"context"
	"os"
	"strings"
)

// AdminKubeconfig returns the kubeconfig holding the admin context name: the
// host file when it lists that context, the account file otherwise.
func AdminKubeconfig(contextName string) string {
	return Kube{}.AdminKubeconfig(contextName)
}

// AdminKubeconfig returns the kubeconfig holding the admin context name, with
// the runner of this instance.
func (k Kube) AdminKubeconfig(contextName string) string {
	host := os.Getenv("DEVZONE_KUBE_HOST")
	if host == "" {
		host = configPath("hote.config")
	}
	fallback := os.Getenv("DEVZONE_KUBE_CONFIG")
	if fallback == "" {
		fallback = configPath("config")
	}
	if contextName == "" || !isFile(host) {
		return fallback
	}
	res, err := k.Run(context.Background(), host, "config", "get-contexts", "-o", "name")
	if err != nil || res.Code != 0 {
		return fallback
	}
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(line) == contextName {
			return host
		}
	}
	return fallback
}

// isFile reports whether path is an existing regular file.
func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
