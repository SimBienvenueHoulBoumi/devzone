// Package state reads and writes the .devzone.modules file (key=value lines),
// keeping unknown lines in order and guarding writes with a directory lock.
package state

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// lock takes the write lock: mkdir lockdir, then flock when available. It is
// reentrant within the same State value so init/replace can nest like the shell.
func (s *State) lock() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.depth > 0 {
		s.depth++
		return nil
	}
	dir := s.Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	lockDir := s.lockDir()
	start := time.Now()
	for {
		if err := os.Mkdir(lockDir, 0o755); err == nil {
			break
		} else if !os.IsExist(err) {
			return err
		}
		if stale(lockDir, 30*time.Second) {
			_ = os.RemoveAll(lockDir)
			continue
		}
		if time.Since(start) >= 10*time.Second {
			return fmt.Errorf("devzone : state locked elsewhere: %s", lockDir)
		}
		time.Sleep(1 * time.Second)
	}
	if err := s.flockTake(lockDir); err != nil {
		return err
	}
	s.depth = 1
	return nil
}

// flockTake acquires the flock companion file. The mkdir lockdir stays the guard
// on systems without flock; on Linux it serializes writes like the shell.
func (s *State) flockTake(lockDir string) error {
	f, err := os.OpenFile(s.flockFile(), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		_ = os.RemoveAll(lockDir)
		return fmt.Errorf("devzone : state locked elsewhere (flock): %s", s.flockFile())
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			s.flockFd = f
			return nil
		}
		if err != syscall.EAGAIN && err != syscall.EWOULDBLOCK {
			_ = f.Close()
			_ = os.RemoveAll(lockDir)
			return fmt.Errorf("devzone : state locked elsewhere (flock): %s", s.flockFile())
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			_ = os.RemoveAll(lockDir)
			return fmt.Errorf("devzone : state locked elsewhere (flock): %s", s.flockFile())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// unlock releases one depth level; the last level drops flock then the lockdir.
func (s *State) unlock() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.depth <= 0 {
		return
	}
	if s.depth > 1 {
		s.depth--
		return
	}
	s.depth = 0
	if s.flockFd != nil {
		_ = syscall.Flock(int(s.flockFd.Fd()), syscall.LOCK_UN)
		_ = s.flockFd.Close()
		s.flockFd = nil
	}
	_ = os.RemoveAll(s.lockDir())
}

// lockDir returns the mkdir lock directory used by shell and Go writers.
func (s *State) lockDir() string { return s.path + ".lockdir" }

// flockFile returns the flock companion file used on Linux.
func (s *State) flockFile() string { return s.path + ".lock" }

// stale reports whether a lockdir is older than maxAge.
func stale(lockDir string, maxAge time.Duration) bool {
	info, err := os.Stat(lockDir)
	if err != nil {
		return false
	}
	return time.Since(info.ModTime()) > maxAge
}
