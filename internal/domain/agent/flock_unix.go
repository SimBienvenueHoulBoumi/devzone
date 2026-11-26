//go:build !windows

package agent

import (
	"os"
	"syscall"
	"time"
)

// flockWait takes an exclusive flock with a timeout (flock -w); loops NB.
func flockWait(f *os.File, sec int) bool {
	deadline := time.Now().Add(time.Duration(sec) * time.Second)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// flockUnlock releases a flock (flock -u).
func flockUnlock(f *os.File) { syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }
