package podcmd

import (
	"strings"
	"testing"
)

// TestMigrateLLMOnce checks that the llm line is dropped with one notice, even when a
// module is changed afterwards.
func TestMigrateLLMOnce(t *testing.T) {
	f := newModuleFixture(t, "llm=off", "ai=off")
	f.m.migrateLLM()
	f.m.migrateLLM()
	if strings.Count(f.out.String(), "llm module removed") != 1 {
		t.Fatalf("notice count wrong: %q", f.out.String())
	}
	if f.state(t) != "ai=off\n" {
		t.Fatalf("state = %q", f.state(t))
	}
}

// TestModuleCommandsRegistered checks that the module commands are handled by the pod binary.
func TestModuleCommandsRegistered(t *testing.T) {
	for _, name := range []string{"enable", "disable", "is-enabled", "apply"} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%s not registered", name)
		}
	}
}
