//go:build windows

package state

import (
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// Win32 lock flags: fail instead of waiting, and take an exclusive range lock.
const (
	lockfileFailImmediately = 0x00000001
	lockfileExclusiveLock   = 0x00000002
)

// The Win32 byte-range lock is the Windows equivalent of flock: it excludes
// other processes holding the companion file, without an external dependency.
var (
	kernel32DLL      = syscall.NewLazyDLL("kernel32.dll")
	lockFileExProc   = kernel32DLL.NewProc("LockFileEx")
	unlockFileExProc = kernel32DLL.NewProc("UnlockFileEx")
)

// overlapped is the Win32 OVERLAPPED structure of LockFileEx and UnlockFileEx.
type overlapped struct {
	internal     uintptr
	internalHigh uintptr
	offset       uint32
	offsetHigh   uint32
	hEvent       syscall.Handle
}

// takeFlock takes the exclusive Win32 byte-range lock on the companion file,
// retrying until the deadline; on failure the caller drops the mkdir lockdir.
func takeFlock(path, lockDir string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		_ = os.RemoveAll(lockDir)
		return nil, fmt.Errorf("devzone : state locked elsewhere (lock): %s", path)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		var region overlapped
		r, _, _ := lockFileExProc.Call(f.Fd(), lockfileExclusiveLock|lockfileFailImmediately,
			0, 1, 0, uintptr(unsafe.Pointer(&region)))
		if r != 0 {
			return f, nil
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			_ = os.RemoveAll(lockDir)
			return nil, fmt.Errorf("devzone : state locked elsewhere (lock): %s", path)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// releaseFlock drops the Win32 byte-range lock held on f before it is closed.
func releaseFlock(f *os.File) error {
	var region overlapped
	r, _, _ := unlockFileExProc.Call(f.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&region)))
	if r == 0 {
		return fmt.Errorf("devzone : state lock release failed: %s", f.Name())
	}
	return nil
}
