package kube

import (
	"os"
	"path/filepath"
)

// MessageError is a failure whose text the account command prints on its error
// output, like the messages written by the shell token cycle.
type MessageError struct {
	Text string
}

// Error returns the message of the shell original, without the devzone prefix.
func (e MessageError) Error() string { return e.Text }

// Limited Kubernetes account of the devzone services (#430): the ServiceAccount
// devzone-agent of the devzone-system namespace, bound to the edit ClusterRole
// in each devzone namespace by a RoleBinding, with a 24 h TokenRequest token.
const (
	accountNamespace      = "devzone-system"
	accountServiceAccount = "devzone-agent"
	accountDuration       = "24h"
	accountContextName    = "devzone"
	accountLabel          = "app.kubernetes.io/managed-by=devzone"
)

// accountKubeconfigPath returns the kubeconfig holding the limited account
// context (the account file), from DEVZONE_KUBE_CONFIG or the default one.
func accountKubeconfigPath() string {
	if path := os.Getenv("DEVZONE_KUBE_CONFIG"); path != "" {
		return path
	}
	return configPath("config")
}

// agentKubeconfigPath returns the kubeconfig of the agents, from
// DEVZONE_KUBE_AGENT_CONFIG or the default one.
func agentKubeconfigPath() string {
	if path := os.Getenv("DEVZONE_KUBE_AGENT_CONFIG"); path != "" {
		return path
	}
	return configPath("agent.config")
}

// tokenExpiryPath returns the expiry file of the limited account token, from
// DEVZONE_KUBE_TOKEN_EXPIRY or the default one.
func tokenExpiryPath() string {
	if path := os.Getenv("DEVZONE_KUBE_TOKEN_EXPIRY"); path != "" {
		return path
	}
	return filepath.Join(home(), ".kube", "devzone-token.expiry")
}
