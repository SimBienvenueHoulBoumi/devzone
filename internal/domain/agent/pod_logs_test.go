package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestAgentPodFetchLogs checks that init logs come before the agent log, that a
// failing kubectl logs -c is not fatal and that no init keeps the journal clean.
func TestAgentPodFetchLogs(t *testing.T) {
	k := &kubectlFake{resp: func(args []string) dzexec.Result {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, "initContainers[*].name"):
			return dzexec.Result{Stdout: []byte("premier guard")}
		case strings.Contains(joined, "logs ") && strings.Contains(joined, "-c premier"):
			return dzexec.Result{Stdout: []byte("init line\n")}
		case strings.Contains(joined, "logs ") && strings.Contains(joined, "-c guard"):
			return dzexec.Result{Code: 1}
		case strings.Contains(joined, "logs "):
			return dzexec.Result{Stdout: []byte("agent line\n")}
		}
		return dzexec.Result{}
	}}
	journal := filepath.Join(t.TempDir(), "j.log")
	os.WriteFile(journal, nil, 0o644)
	AgentPodFetchLogs(context.Background(), k, "p", journal)
	data := readFileString(journal)
	first := strings.Index(data, "=== init container premier ===")
	second := strings.Index(data, "=== init container guard ===")
	agent := strings.Index(data, "agent line")
	if first < 0 || second < 0 || agent < 0 || !(first < second && second < agent) {
		t.Fatalf("wrong log order: %s", data)
	}
	if !strings.Contains(data, "init line") {
		t.Fatalf("init log missing: %s", data)
	}
	clean := filepath.Join(t.TempDir(), "clean.log")
	os.WriteFile(clean, nil, 0o644)
	none := &kubectlFake{resp: func(args []string) dzexec.Result {
		if strings.Contains(strings.Join(args, " "), "logs ") {
			return dzexec.Result{Stdout: []byte("agent line\n")}
		}
		return dzexec.Result{}
	}}
	AgentPodFetchLogs(context.Background(), none, "p", clean)
	if data := readFileString(clean); strings.Contains(data, "=== init container") || !strings.Contains(data, "agent line") {
		t.Fatalf("no-init journal: %s", data)
	}
}
