package gitlab

import (
	"os"
	"strings"
	"testing"
)

// valuesBlock returns the block of the file values under the heading "    <name>:"
// (the awk of the values tests of gitlab.bats).
func valuesBlock(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile("../../../charts/devzone-gitlab/values.yaml")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(data), "\n")
	heading := "    " + name + ":"
	var out []string
	inside := false
	for _, line := range lines {
		switch {
		case line == heading:
			inside = true
		case inside && (strings.HasPrefix(line, "    ") && line != "" && !strings.HasPrefix(line, "      ")):
			inside = false
		}
		if inside {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// TestValuesPins checks the values of the wrapper chart (gitlab.bats
// "values.yaml pins the HPAs to 1 replica (#490)").
func TestValuesPins(t *testing.T) {
	for _, name := range []string{"webservice", "sidekiq", "gitlab-shell"} {
		block := valuesBlock(t, name)
		if !strings.Contains(block, "minReplicas: 1") || !strings.Contains(block, "maxReplicas: 1") {
			t.Errorf("block %q lacks the 1 replica pins", name)
		}
	}
}

// TestValuesNoExposure checks that the services are ClusterIP without
// NodePort, LoadBalancer or hostPort (gitlab.bats).
func TestValuesNoExposure(t *testing.T) {
	data, err := os.ReadFile("../../../charts/devzone-gitlab/values.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"NodePort", "LoadBalancer", "hostPort"} {
		if strings.Contains(string(data), forbidden) {
			t.Errorf("values.yaml has %s", forbidden)
		}
	}
}
