package exec

import (
	"context"
	"strings"
)

// DevzoneContextName is the name of the services cluster context in kubeconfig.
const DevzoneContextName = "devzone"

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
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(line) == DevzoneContextName {
			return []string{flagName, DevzoneContextName}
		}
	}
	return nil
}
