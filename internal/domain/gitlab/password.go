package gitlab

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/passwords"
)

// regeneratePasswords refreshes the grouped credentials view with the shared
// Go library, without invoking a shell or passing a secret to a command (#881).
// The caller decides how to report a failure.
func (r *run) regeneratePasswords() int {
	if err := passwords.Regenerate(r.root); err != nil {
		return 1
	}
	return 0
}
