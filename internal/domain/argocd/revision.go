package argocd

import (
	"context"

	rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"
)

// RevisionInputs carries the inputs used to resolve the revision of the
// Applications. The type belongs to the shared rule so that the launcher and
// the pod module use the same resolution without linking each other.
type RevisionInputs = rule.RevisionInputs

// ResolveRevision returns the revision of the devzone charts through the
// shared rule. It never returns an empty revision: without one, the caller
// must fail instead of silently installing with helm.
func ResolveRevision(ctx context.Context, in RevisionInputs) (string, error) {
	return rule.ResolveRevision(ctx, in)
}
