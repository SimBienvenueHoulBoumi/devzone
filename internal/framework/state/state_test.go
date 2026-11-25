package state

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestStateReadWriteUnknownAndLock(t *testing.T) {
	dir := t.TempDir()
	s := New(dir)
	if err := os.WriteFile(filepath.Join(dir, ".devzone.modules"), []byte("foo=bar\nunknown line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.Get("foo"); got != "bar" {
		t.Fatalf("get=%q", got)
	}
	if _, ok := s.GetOK("missing"); ok {
		t.Fatal("missing should be absent")
	}
	if err := s.Set("foo", "baz"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, ".devzone.modules"))
	if string(data) != "unknown line\nfoo=baz\n" {
		t.Fatalf("data=%q", string(data))
	}
	if err := s.Delete("foo"); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(filepath.Join(dir, ".devzone.modules"))
	if string(data) != "unknown line\n" {
		t.Fatalf("data=%q", string(data))
	}

	// concurrency smoke test
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			st := New(dir)
			_ = st.Set("k", string(rune('a'+n)))
		}(i)
	}
	wg.Wait()
}

func TestStateHelpers(t *testing.T) {
	dir := t.TempDir()
	if err := Set(dir, "a", "1"); err != nil {
		t.Fatal(err)
	}
	if got := Get(dir, "a"); got != "1" {
		t.Fatalf("got=%q", got)
	}
	if err := Delete(dir, "a"); err != nil {
		t.Fatal(err)
	}
	if got := Get(dir, "a"); got != "" {
		t.Fatalf("got=%q", got)
	}
}

// TestStateAtFreeName checks that At reads and writes a state file of any name,
// as DEVZONE_STATE allows.
func TestStateAtFreeName(t *testing.T) {
	file := filepath.Join(t.TempDir(), "modules")
	if err := os.WriteFile(file, []byte("cluster=kind-devzone\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := At(file)
	if got := s.Get("cluster"); got != "kind-devzone" {
		t.Fatalf("get=%q", got)
	}
	if err := s.Set("mysql", "on"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(file)
	if string(data) != "cluster=kind-devzone\nmysql=on\n" {
		t.Fatalf("data=%q", string(data))
	}
}
