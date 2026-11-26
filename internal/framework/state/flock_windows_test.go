//go:build windows

package state

import (
	"os"
	"path/filepath"
	"testing"
	"unsafe"
)

// TestWindowsFileLockExcludesOtherHandles checks that the Win32 range lock used
// on Windows is exclusive: a second handle cannot take it while the first holds
// it, and can take it again after release.
func TestWindowsFileLockExcludesOtherHandles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.lock")
	first, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	f, err := takeFlock(path, filepath.Dir(path))
	if err != nil {
		t.Fatalf("first take: %v", err)
	}
	defer func() {
		_ = releaseFlock(f)
		_ = f.Close()
	}()

	other, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	var region overlapped
	r, _, _ := lockFileExProc.Call(other.Fd(), lockfileExclusiveLock|lockfileFailImmediately,
		0, 1, 0, uintptr(unsafe.Pointer(&region)))
	if r != 0 {
		t.Fatal("second handle took the lock while the first held it")
	}
	if err := releaseFlock(f); err != nil {
		t.Fatalf("release: %v", err)
	}
	r, _, _ = lockFileExProc.Call(other.Fd(), lockfileExclusiveLock|lockfileFailImmediately,
		0, 1, 0, uintptr(unsafe.Pointer(&region)))
	if r == 0 {
		t.Fatal("second handle could not take the lock after release")
	}
	_ = releaseFlock(other)
}

// TestWindowsStateLockRoundTrip checks that the shared State lock path takes
// and releases the Windows lock and leaves no lock directory behind.
func TestWindowsStateLockRoundTrip(t *testing.T) {
	s := At(filepath.Join(t.TempDir(), ".devzone.modules"))
	if err := s.lock(); err != nil {
		t.Fatalf("lock: %v", err)
	}
	if s.flockFd == nil {
		t.Fatal("no OS lock was taken on Windows")
	}
	s.unlock()
	if s.flockFd != nil {
		t.Fatal("OS lock was not released")
	}
	if _, err := os.Stat(s.lockDir()); !os.IsNotExist(err) {
		t.Fatalf("lockdir left behind: %v", err)
	}
}
