package mysql

import (
	"context"
)

// Claim writes the volume claim prefix to reuse in a namespace: "donnees"
// without a PVC, the prefix of the single PVC, or the refusal of volume.sh
// when several PVCs exist. It replaces the shell helper of app.sh, with the
// same kubectl calls on the devzone context and the same exit status.
func Claim(ctx context.Context, opts Options, args []string) int {
	if len(args) == 0 {
		return usage(opts)
	}
	e := newEnv(ctx, opts)
	claim, code := e.claimChoose(args[0])
	if code != 0 {
		return code
	}
	e.line("%s", claim)
	return 0
}
