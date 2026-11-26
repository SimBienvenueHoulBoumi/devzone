package catalog

import (
	"os"
	"strings"
	"testing"
)

// TestShellMetrics checks that options are passed to the metrics installer.
func TestShellMetrics(t *testing.T) {
	app, actions, _ := shellApp(t)
	if _, code := runShellApp(t, app, "metrics", "docker-desktop", "--force"); code != 0 {
		t.Fatalf("metrics: code %d", code)
	}
	if got := strings.TrimSpace(readLog(t, actions)); got != "metrics docker-desktop --force" {
		t.Fatalf("actions = %q", got)
	}
}

// TestShellUse checks the context switch without touching the services cluster.
func TestShellUse(t *testing.T) {
	app, _, state := shellApp(t)
	writeTestFile(t, state, "cluster=kind-devzone\n")
	out, code := runShellApp(t, app, "use", "docker-desktop")
	if code != 0 {
		t.Fatalf("use: code %d, output %q", code, out)
	}
	if !strings.Contains(out, "working cluster: docker-desktop") {
		t.Fatalf("use output = %q", out)
	}
	kubectl := os.Getenv("BATS_TEST_TMPDIR_ACTIONS") + ".kubectl"
	if !strings.Contains(readLog(t, kubectl), "config use-context docker-desktop") {
		t.Fatalf("kubectl = %q", readLog(t, kubectl))
	}
	if got := strings.TrimSpace(readLog(t, state)); got != "cluster=kind-devzone" {
		t.Fatalf("state = %q", got)
	}
}

// TestShellUseRefusals checks unknown and remote contexts without switching.
func TestShellUseRefusals(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"use", "inconnu"}, "unknown context: inconnu"},
		{[]string{"use", "prod"}, "remote cluster refused: prod"},
		{[]string{"use", "prod", "--confirm", "autre"}, "remote cluster refused: prod"},
	} {
		t.Run(tc.want, func(t *testing.T) {
			app, _, _ := shellApp(t)
			out, code := runShellApp(t, app, tc.args...)
			if code != 2 {
				t.Fatalf("use: code %d, want 2", code)
			}
			if !strings.Contains(out, tc.want) {
				t.Fatalf("use output = %q", out)
			}
			kubectl := os.Getenv("BATS_TEST_TMPDIR_ACTIONS") + ".kubectl"
			if strings.Contains(readLog(t, kubectl), "use-context") {
				t.Fatalf("kubectl switched: %q", readLog(t, kubectl))
			}
		})
	}
}

// TestShellUseConfirm checks that the exact confirmation accepts a remote context.
func TestShellUseConfirm(t *testing.T) {
	app, _, _ := shellApp(t)
	if _, code := runShellApp(t, app, "use", "prod", "--confirm", "prod"); code != 0 {
		t.Fatalf("use: code %d", code)
	}
	kubectl := os.Getenv("BATS_TEST_TMPDIR_ACTIONS") + ".kubectl"
	if !strings.Contains(readLog(t, kubectl), "config use-context prod") {
		t.Fatalf("kubectl = %q", readLog(t, kubectl))
	}
}

// readLog returns the whole content of a test log file.
func readLog(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
