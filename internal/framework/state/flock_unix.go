//go:build !windows

package state

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// takeFlock acquires an exclusive non-blocking flock on the companion file,
// retrying until the deadline; on failure the caller drops the mkdir lockdir.
func takeFlock(path, lockDir string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		_ = os.RemoveAll(lockDir)
		return nil, fmt.Errorf("devzone : state locked elsewhere (flock): %s", path)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != syscall.EAGAIN && err != syscall.EWOULDBLOCK {
			_ = f.Close()
			_ = os.RemoveAll(lockDir)
			return nil, fmt.Errorf("devzone : state locked elsewhere (flock): %s", path)
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			_ = os.RemoveAll(lockDir)
			return nil, fmt.Errorf("devzone : state locked elsewhere (flock): %s", path)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// releaseFlock drops the flock held on f before the file is closed.
func releaseFlock(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
