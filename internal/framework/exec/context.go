package exec

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// DevzoneContextName is the default name of the services cluster context in
// kubeconfig. Keep the literal here so no command writes it by hand.
const DevzoneContextName = "devzone"

// KubectlContextFlagName is the kubectl flag that selects a kubeconfig context.
// Kept here so the flag name has a single home.
const KubectlContextFlagName = "--context"

// HelmContextFlagName is the helm flag that selects a kubeconfig context.
// Kept here so the flag name has a single home.
const HelmContextFlagName = "--kube-context"

// ContextName returns the services context name, letting a workstation choose
// another kubeconfig entry without changing the code. Resolution order: the
// DEVZONE_CONTEXT variable when set, then the context key of the [cluster]
// section of .argocd.conf, then "devzone". The file is read from DEVZONE_ROOT
// when that is set, otherwise from the current folder; parents are never searched.
func ContextName() string {
	if name := os.Getenv("DEVZONE_CONTEXT"); name != "" {
		return name
	}
	dir := os.Getenv("DEVZONE_ROOT")
	if dir == "" {
		dir = "."
	}
	if name := config.GetKeyInSection(filepath.Join(dir, ".argocd.conf"), "cluster", "context"); name != "" {
		return name
	}
	return DevzoneContextName
}

// DevzoneContextFlag returns the flag that selects the services context for the
// given program when kubeconfig declares it. Without that context it returns no
// flag, so kubectl and helm use the current context of the workstation (#916).
// The flagName is "--context" for kubectl and "--kube-context" for helm.
func DevzoneContextFlag(ctx context.Context, r Runner, flagName string) []string {
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := r.Run(ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, Opts{})
	if err != nil || res.Code != 0 {
		return nil
	}
	name := ContextName()
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(line) == name {
			return []string{flagName, name}
		}
	}
	return nil
}

// DevzoneKubectlContextFlag selects the services context for kubectl, returning
// the flag only when kubeconfig declares that context.
func DevzoneKubectlContextFlag(ctx context.Context, r Runner) []string {
	return DevzoneContextFlag(ctx, r, KubectlContextFlagName)
}

// DevzoneHelmContextFlag selects the services context for helm, returning the
// flag only when kubeconfig declares that context.
func DevzoneHelmContextFlag(ctx context.Context, r Runner) []string {
	return DevzoneContextFlag(ctx, r, HelmContextFlagName)
}
