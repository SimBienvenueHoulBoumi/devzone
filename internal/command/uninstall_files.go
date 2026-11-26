package command

import (
	"os"
	"path/filepath"
	"strings"
)

func listDevzoneFiles(root string) []string {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".devzone.") {
			out = append(out, filepath.Join(root, name))
		}
	}
	return out
}

// kubectlLines runs kubectl on the services cluster context and returns
// non-empty output lines. A failing list stops the caller: a partial plan
// would silently keep or delete the wrong objects. Only the missing resource
// type of an uninstalled CRD is reported apart, as errMissingResourceType.
