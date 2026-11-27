package podcmd

import (
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// TestStatusSaysWhichServicesAreHeld checks that status reports the Argo CD
// ownership of each service and says nothing for the other modules, using a
// disposable state and a stub runner that answers no command.
func TestStatusSaysWhichServicesAreHeld(t *testing.T) {
	_, code, stateFile := jsonFixture(t)
	writeJSONFile(t, stateFile, "gitlab=on\npostgres=on\nmysql=on\nargocd=on\n")
	responses := map[string]exec.Result{}
	runner := stubRunner{t: t, responses: responses}
	runner.program(nil, 0, "gitlab ready\n", "devzone", "gitlab", "status")
	runner.program(nil, 0, "postgres ready\n", "bash", code+"/postgres/postgres.sh", "status")
	runner.program(nil, 0, "argocd ready\n", code+"/devzone", "argocd", "status")
	runner.program(nil, 0, "mysql ready\n", "devzone", "mysql", "status")
	st := state.New(stateFile)
	d := jsonDeps{
		ctx:  &cli.Context{Runner: runner},
		st:   st,
		root: t.TempDir(),
		code: code,
	}
	mods, _ := modulesJSON(d, jsonObject{})
	want := map[string]bool{
		"ai": false, "kubernetes": false, "gitlab": true,
		"postgres": true, "argocd": false, "mysql": true,
	}
	for _, value := range mods {
		mod, ok := value.(jsonObject)
		if !ok {
			t.Fatalf("module entry is not an object: %T", value)
		}
		name, _ := mod[0].value.(string)
		held, _ := mod[6].value.(bool)
		if expected, ok := want[name]; !ok || held != expected {
			t.Errorf("module %s: held-by-argocd = %v, want %v", name, held, expected)
		}
	}
	if len(mods) != len(want) {
		t.Fatalf("modules = %d, want %d", len(mods), len(want))
	}
}
