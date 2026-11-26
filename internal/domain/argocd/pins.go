package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// metricsPins reads the metrics-server pins from versions.env, the single
// declaration of the versions pinned by the project. The file sits in the
// shipped .devcontainer folder, the same one as the cluster scripts.
func (m *module) metricsPins() (chart, app string, err error) {
	path := filepath.Join(m.codeRoot, "versions.env")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", "", fmt.Errorf("metrics-server : pinned versions unreadable: %s : %w", path, err)
	}
	chart = envValue(string(data), "METRICS_SERVER_CHART_VERSION")
	app = envValue(string(data), "METRICS_SERVER_VERSION")
	if chart == "" || app == "" {
		return "", "", fmt.Errorf("metrics-server : METRICS_SERVER_CHART_VERSION or METRICS_SERVER_VERSION missing in %s", path)
	}
	return chart, app, nil
}

// envValue returns the value of key in a KEY=value file, or "" when absent.
// Comment lines and blank lines never match.
func envValue(text, key string) string {
	for _, line := range strings.Split(text, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && k == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
