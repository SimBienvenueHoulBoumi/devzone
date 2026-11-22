package podcmd

import (
	"errors"
	"os"
)

// defaultScript is the pod shell entry point installed by the image; a variable so that tests can point elsewhere.
var defaultScript = "/usr/local/share/devzone/.devcontainer/devzone"

// podScript returns the shell entry point of the pod: DEVZONE_POD_SCRIPT when it is a file, else the one installed in the image.
func podScript() (string, error) {
	if script := os.Getenv("DEVZONE_POD_SCRIPT"); script != "" {
		if _, err := os.Stat(script); err == nil {
			return script, nil
		}
	}

	script := defaultScript
	if _, err := os.Stat(script); err == nil {
		return script, nil
	}

	return "", errors.New("pod shell entry point not found")
}
