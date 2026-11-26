package catalog

import (
	"os"
)

// sync adds the missing <app>=off lines under the same state lock as the shell
// did: the Go state command owns the lock, this command only delegates to it.
func (e *env) sync() int {
	if _, err := os.Stat(e.statePath); err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		e.warn("%v", err)
		return 1
	}
	res, err := e.exec("bash", []string{e.script, "state", "catalog-sync"},
		"DEVZONE_STATE="+e.statePath)
	if err != nil {
		e.warn("%v", err)
		return 1
	}
	if res.Code != 0 {
		if len(res.Stderr) > 0 {
			e.warn("%s", string(res.Stderr))
		}
		return res.Code
	}
	return 0
}
