package state

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestShellRebuildGoEquivalent checks frozen state_rebuild results with a
// fake kubectl (never a real cluster): rebuilt state, .prev, exit code and
// warnings, taken from the shell comparison before state.sh was removed.
func TestShellRebuildGoEquivalent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(dir, "host.config"))
	t.Setenv("HOME", dir)
	modules := defaultModules()
	var warns []string
	rebuilt, err := At(path).Rebuild(modules, fakeKubectlRebuild(), func(m string) { warns = append(warns, m) })
	if err != nil || !rebuilt { // state_rebuild: code 0, rebuilt
		t.Fatalf("code/rebuilt rebuilt=%v err=%v, want frozen code 0 rebuilt", rebuilt, err)
	}
	assertFile(t, path, "ai=off\nkubernetes=off\ngitlab=on\npostgres=on\nargocd=off\nmysql=off\ncluster=docker-desktop\n")
	assertPrev(t, path+".prev", false, "")
	if len(warns) != 1 || !strings.Contains(warns[0], "state rebuilt from the namespaces") {
		t.Fatalf("warnings %q", warns)
	}
}

// fakeKubectlRebuild returns a fake kubectl runner like the shell fake used by
// the former comparison, never a real cluster.
func fakeKubectlRebuild() Runner {
	return fakeKubectlFunc([]string{"devzone-postgres", "devzone-gitlab"}, func(joined string) (string, bool) {
		if strings.Contains(joined, "config view") && strings.Contains(joined, "devzone") {
			return "kind-devzone\n", true
		}
		if strings.Contains(joined, "config get-contexts") {
			return "devzone\ndocker-desktop\n", true
		}
		if strings.Contains(joined, "docker-desktop") {
			return "kind-devzone\n", true
		}
		return "", false
	})
}
