package command

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// TestWorkstationArgoCDCommands checks that init, apply and app reach the
// shared Argo CD library with the folders of the workstation folder, without
// calling a cluster, gh or the network.
func TestWorkstationArgoCDCommands(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	previous := workstationArgoCDRun
	installed, holds := commandArgoCDInstalled, commandArgoCDHoldsCharts
	t.Cleanup(func() {
		workstationArgoCDRun = previous
		commandArgoCDInstalled, commandArgoCDHoldsCharts = installed, holds
	})
	commandArgoCDInstalled = func(workspace.Runner) bool { return true }
	commandArgoCDHoldsCharts = func(workspace.Runner, string) bool { return false }
	var calls [][]string
	var seen argocd.Options
	workstationArgoCDRun = func(_ context.Context, args []string, _, _ io.Writer, opts argocd.Options) int {
		calls = append(calls, append([]string(nil), args...))
		seen = opts
		return 0
	}
	for _, args := range [][]string{
		{"workspace", "argocd", "init", "--none"},
		{"workspace", "argocd", "apply"},
		{"workspace", "argocd", "app", "add", "https://example.test/projet.git"},
		{"workspace", "argocd", "app", "list"},
		{"workspace", "argocd", "app", "remove", "app-projet"},
	} {
		ctx := &cli.Context{Args: args[1:], Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
		if code := workspaceCommand(ctx); code != 0 {
			t.Fatalf("%v: status = %d, calls=%v", args, code, calls)
		}
	}
	want := []string{"init --none", "apply", "app add https://example.test/projet.git", "app list", "app remove app-projet"}
	if len(calls) != len(want) {
		t.Fatalf("calls = %v, want %v", calls, want)
	}
	for i, call := range calls {
		if strings.Join(call, " ") != want[i] {
			t.Fatalf("call %d = %q, want %q", i, strings.Join(call, " "), want[i])
		}
	}
	if seen.Root != root || seen.StatePath != filepath.Join(root, ".devzone.modules") ||
		!strings.HasSuffix(seen.CodeRoot, string(filepath.Separator)+".devcontainer") {
		t.Fatalf("options = %+v", seen)
	}
	if seen.Runner == nil || seen.Out == nil || seen.Err == nil {
		t.Fatal("the library has no runner or writers")
	}
}

// TestServicesArgoCDInstallAndUninstall checks that enabling and disabling the
// module call install and uninstall, and that only a success notes the state.
func TestServicesArgoCDInstallAndUninstall(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("cluster=kind-devzone\nworkspace=kubernetes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	previous := workstationArgoCDRun
	t.Cleanup(func() { workstationArgoCDRun = previous })
	var calls []string
	status := 0
	workstationArgoCDRun = func(_ context.Context, args []string, _, _ io.Writer, _ argocd.Options) int {
		calls = append(calls, strings.Join(args, " "))
		return status
	}
	if code := commandServices([]string{"services", "enable", "argocd"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
		t.Fatalf("enable status = %d", code)
	}
	data, err := os.ReadFile(filepath.Join(root, ".devzone.modules"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "argocd=on") || !strings.Contains(string(data), "cluster=kind-devzone") {
		t.Fatalf("modules = %q", data)
	}
	status = 2
	if code := commandServices([]string{"services", "disable", "argocd"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 2 {
		t.Fatalf("disable status = %d", code)
	}
	data, err = os.ReadFile(filepath.Join(root, ".devzone.modules"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "argocd=off") {
		t.Fatalf("a failed uninstall changed the state: %q", data)
	}
	if strings.Join(calls, ",") != "install,uninstall" {
		t.Fatalf("calls = %v", calls)
	}
}
