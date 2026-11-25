package cli

import (
	"bytes"
	"testing"
)

func TestRegistryLookupAliasBareRun(t *testing.T) {
	r := NewRegistry()
	called := false
	r.Register(Command{
		Name:    "cmd",
		Aliases: []string{"c"},
		Bare:    true,
		Run:     func(ctx *Context) int { called = true; return 7 },
	})
	cmd, ok := r.Lookup("c")
	if !ok || cmd.Name != "cmd" {
		t.Fatalf("alias lookup failed: %v %v", ok, cmd)
	}
	names := r.Names()
	if len(names) != 2 {
		t.Fatalf("names = %v", names)
	}
	var out bytes.Buffer
	code, ok := r.Run([]string{"cmd"}, &Context{Out: &out})
	if !ok || code != 7 || !called {
		t.Fatalf("run = %d %v", code, ok)
	}
	// bare with arg delegates via Delegate
	delegateCalled := false
	r2 := NewRegistry()
	r2.Register(Command{
		Name:     "bare",
		Bare:     true,
		Run:      func(ctx *Context) int { return 0 },
		Delegate: func(ctx *Context) int { delegateCalled = true; return 3 },
	})
	code, ok = r2.Run([]string{"bare", "x"}, &Context{})
	if !ok || code != 3 || !delegateCalled {
		t.Fatalf("bare delegate = %d %v", code, ok)
	}
	// unknown
	if _, ok := r.Run([]string{"nope"}, &Context{}); ok {
		t.Fatal("unknown should be false")
	}
}
