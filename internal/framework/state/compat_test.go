package state

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestConcurrentWritersNoLineLost(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	s := At(path)
	var wg sync.WaitGroup
	writeN := func(prefix string) {
		defer wg.Done()
		for i := 1; i <= 25; i++ {
			if err := s.Set(prefix+itoa(i), "on"); err != nil {
				t.Errorf("set %s%d: %v", prefix, i, err)
				return
			}
		}
	}
	wg.Add(2)
	go writeN("a")
	go writeN("b")
	wg.Wait()
	content := readFile(t, path)
	for i := 1; i <= 25; i++ {
		if !strings.Contains(content, "a"+itoa(i)+"=on") {
			t.Fatalf("missing a%d", i)
		}
		if !strings.Contains(content, "b"+itoa(i)+"=on") {
			t.Fatalf("missing b%d", i)
		}
	}
}

func TestReaderDuringWritesNeverMissing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(path, []byte("ai=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := At(path)
	stop := make(chan struct{})
	errCh := make(chan error, 1)
	go func() {
		for {
			select {
			case <-stop:
				errCh <- nil
				return
			default:
				if _, err := os.Stat(path); err != nil {
					errCh <- err
					return
				}
			}
		}
	}()
	var wg sync.WaitGroup
	for _, p := range []string{"a", "b"} {
		prefix := p
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 1; i <= 25; i++ {
				_ = s.Set(prefix+itoa(i), "on")
			}
		}()
	}
	wg.Wait()
	close(stop)
	if err := <-errCh; err != nil {
		t.Fatalf("reader saw missing state: %v", err)
	}
}

func TestRestoreFromBackup(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(path+".prev", []byte("ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var warns []string
	s := At(path)
	if err := s.Init(defaultModules(), nil, dir, nil, func(m string) { warns = append(warns, m) }); err != nil {
		t.Fatal(err)
	}
	if s.Get("postgres") != "on" || s.Get("gitlab") != "on" {
		t.Fatalf("state=%q", readFile(t, path))
	}
	if !s.RecoveryPending() || !containsAny(warns, "restored from the backup copy") {
		t.Fatalf("warns=%v pending=%v", warns, s.RecoveryPending())
	}
}

func fakeKubectlRunner(outputs map[string]string) Runner {
	return func(name string, args ...string) (string, string, error) {
		cmd := strings.Join(append([]string{name}, args...), " ")
		if out, ok := outputs[cmd]; ok {
			return out, "", nil
		}
		return "", "", os.ErrNotExist
	}
}

func containsAny(items []string, sub string) bool {
	for _, it := range items {
		if strings.Contains(it, sub) {
			return true
		}
	}
	return false
}

func defaultModules() []string {
	return []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func itoa(i int) string { return fmtInt(int64(i)) }

func fmtInt(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b [32]byte
	pos := len(b)
	for v > 0 {
		pos--
		b[pos] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		pos--
		b[pos] = '-'
	}
	return string(b[pos:])
}
