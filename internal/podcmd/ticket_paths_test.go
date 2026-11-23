package podcmd

import (
	"os"
	"path/filepath"
	"testing"
)

// ticketClone creates <dir>/.git as a directory so that a clone exists at dir.
func ticketClone(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestTicketPathsPod checks the path resolution in the Kubernetes pod workspace.
func TestTicketPathsPod(t *testing.T) {
	root := t.TempDir()
	ticketClone(t, filepath.Join(root, "devzone"))
	ticketClone(t, filepath.Join(root, "repowarden"))
	env := ticketEnv{projects: root, kubernetes: true}

	clone, wt, err := ticketPaths(env, "devzone", "7")
	if err != nil {
		t.Fatalf("ticketPaths(devzone, 7) error = %v", err)
	}
	if clone != filepath.Join(root, "devzone") {
		t.Errorf("clone = %q, want %q", clone, filepath.Join(root, "devzone"))
	}
	if wt != filepath.Join(root, "devzone-wt", "dz-7") {
		t.Errorf("wt = %q, want %q", wt, filepath.Join(root, "devzone-wt", "dz-7"))
	}

	clone, wt, err = ticketPaths(env, "repowarden", "9")
	if err != nil {
		t.Fatalf("ticketPaths(repowarden, 9) error = %v", err)
	}
	if clone != filepath.Join(root, "repowarden") {
		t.Errorf("clone = %q, want %q", clone, filepath.Join(root, "repowarden"))
	}
	if wt != filepath.Join(root, "repowarden-wt", "rw-9") {
		t.Errorf("wt = %q, want %q", wt, filepath.Join(root, "repowarden-wt", "rw-9"))
	}
}

// TestTicketPathsTools checks the path resolution on the workstation tools root.
func TestTicketPathsTools(t *testing.T) {
	tools := t.TempDir()
	ticketClone(t, tools)
	env := ticketEnv{tools: tools}

	clone, wt, err := ticketPaths(env, "devzone", "7")
	if err != nil {
		t.Fatalf("ticketPaths(devzone, 7) error = %v", err)
	}
	if clone != tools {
		t.Errorf("clone = %q, want %q", clone, tools)
	}
	if wt != filepath.Join(tools, "workspace", "wt", "dz-7") {
		t.Errorf("wt = %q, want %q", wt, filepath.Join(tools, "workspace", "wt", "dz-7"))
	}
}

// TestTicketPathsRefusals checks the refusals returned by ticketPaths.
func TestTicketPathsRefusals(t *testing.T) {
	// (a) unknown repo in the pod.
	env := ticketEnv{projects: t.TempDir(), kubernetes: true}
	_, _, err := ticketPaths(env, "nope", "1")
	r, ok := err.(ticketRefusal)
	if !ok {
		t.Fatalf("ticketPaths(nope, 1) error type = %T, want ticketRefusal", err)
	}
	if got := r.Error(); got != "unknown repo: nope (devzone or repowarden)" {
		t.Errorf("error = %q", got)
	}

	// (b) repowarden outside the pod, with a clone of tools.
	tools := t.TempDir()
	ticketClone(t, tools)
	_, _, err = ticketPaths(ticketEnv{tools: tools}, "repowarden", "1")
	r, ok = err.(ticketRefusal)
	if !ok {
		t.Fatalf("ticketPaths(repowarden, 1) error type = %T, want ticketRefusal", err)
	}
	if got := r.Error(); got != "repo repowarden only in the Kubernetes workspace pod" {
		t.Errorf("error = %q", got)
	}

	// (c) pod without clone.
	_, _, err = ticketPaths(ticketEnv{kubernetes: true, projects: ""}, "devzone", "1")
	r, ok = err.(ticketRefusal)
	if !ok {
		t.Fatalf("ticketPaths(devzone, 1) error type = %T, want ticketRefusal", err)
	}
	got := r.Error()
	prefix := "no clone in "
	suffix := "(from the workstation: devzone workspace clone <url>)"
	if len(got) < len(prefix)+len(suffix) || got[:len(prefix)] != prefix || got[len(got)-len(suffix):] != suffix {
		t.Errorf("error = %q, want prefix %q and suffix %q", got, prefix, suffix)
	}
}

// TestTicketEnvFromOS checks the defaults and the environment overrides of ticketEnvFromOS.
func TestTicketEnvFromOS(t *testing.T) {
	t.Setenv("DEVZONE_TICKET_PROJECTS", "/p")
	t.Setenv("DEVZONE_TICKET_TOOLS", "/t")
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	env := ticketEnvFromOS()
	if env.projects != "/p" || env.tools != "/t" || !env.kubernetes {
		t.Errorf("env = %+v, want projects=/p tools=/t kubernetes", env)
	}
	t.Setenv("DEVZONE_TICKET_PROJECTS", "")
	t.Setenv("DEVZONE_TICKET_TOOLS", "")
	t.Setenv("DEVZONE_WORKSPACE", "")
	env = ticketEnvFromOS()
	if env.projects != "/workspaces/projets" || env.tools != "/workspaces/devzone" || env.kubernetes {
		t.Errorf("env = %+v, want projects=/workspaces/projets tools=/workspaces/devzone not kubernetes", env)
	}
}
