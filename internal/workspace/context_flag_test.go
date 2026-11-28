package workspace

import (
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestContextFlagWithoutDeclaredContext checks that no kubectl, helm or watcher
// flag is added when kubeconfig does not declare the services context.
func TestContextFlagWithoutDeclaredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	for _, test := range []struct {
		name string
		flag func(Runner) []string
	}{
		{"kubectl", contextFlag},
		{"helm", helmContextFlag},
		{"watcher", watcherContext},
	} {
		r := &fakeRunner{replies: []reply{{match: contextsCall, stdout: "kind-poste\n"}}}
		if got := test.flag(r); len(got) != 0 {
			t.Errorf("%s: flag = %q, want none", test.name, got)
		}
	}
}

// TestContextFlagUsesOverride checks that DEVZONE_CONTEXT selects another
// declared context for kubectl, helm and the watcher.
func TestContextFlagUsesOverride(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	for _, test := range []struct {
		name string
		flag func(Runner) []string
		want string
	}{
		{"kubectl", contextFlag, "--context"},
		{"helm", helmContextFlag, "--kube-context"},
		{"watcher", watcherContext, "--context"},
	} {
		r := &fakeRunner{replies: []reply{
			{match: contextsCall, stdout: "kind-poste\n" + fexec.ContextName() + "\n"},
		}}
		got := test.flag(r)
		if len(got) != 2 || got[0] != test.want || got[1] != fexec.ContextName() {
			t.Errorf("%s: flag = %q, want %q %q", test.name, got, test.want, fexec.ContextName())
		}
	}
}
