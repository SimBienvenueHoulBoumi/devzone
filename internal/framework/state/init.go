package state

import (
	"fmt"
	"os"
	"path/filepath"
)

// Runner executes a command and returns stdout, stderr, and error. It lets init
// and rebuild probe kubectl without depending on the full framework runner.
type Runner func(name string, args ...string) (stdout string, stderr string, err error)

// Init creates the state when missing: former global state moved once, backup
// copy restored, state rebuilt from the services cluster, otherwise defaults.
func (s *State) Init(modules []string, run Runner, home string, credentialsFound func() bool, warn func(string)) error {
	if _, err := os.Stat(s.path); err == nil {
		return nil
	}
	if home == "" {
		home = os.Getenv("HOME")
	}
	if warn == nil {
		warn = func(string) {}
	}
	if migrated, err := s.migrateGlobal(home); err != nil {
		return err
	} else if migrated {
		return nil
	}
	if err := s.lock(); err != nil {
		return err
	}
	if _, err := os.Stat(s.path); err == nil {
		s.unlock()
		return nil
	}
	if restored, err := s.restoreBackupLocked(warn); err != nil {
		s.unlock()
		return err
	} else if restored {
		s.unlock()
		return nil
	}
	if rebuilt, err := s.rebuildLocked(modules, run, warn); err != nil {
		s.unlock()
		return err
	} else if rebuilt {
		s.unlock()
		return nil
	}
	if err := s.writeDefaultLocked(); err != nil {
		s.unlock()
		return err
	}
	s.unlock()
	if credentialsFound != nil && credentialsFound() {
		warn("devzone : shared Claude Code/opencode connection found: devzone enable ai to use it here")
	}
	return nil
}

// migrateGlobal moves the former global state into this instance state once.
func (s *State) migrateGlobal(home string) (bool, error) {
	global := filepath.Join(home, ".config", "devzone", "modules")
	if _, err := os.Stat(global); err != nil {
		return false, nil
	}
	if err := s.Replace(global); err != nil {
		return false, err
	}
	if err := os.Remove(global); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	return true, nil
}

// restoreBackupLocked restores .prev when the state is missing.
func (s *State) restoreBackupLocked(warn func(string)) (bool, error) {
	prev := s.prevPath()
	if _, err := os.Stat(prev); err != nil {
		return false, nil
	}
	data, err := os.ReadFile(prev)
	if err != nil {
		return false, err
	}
	if err := s.replaceBytesLocked(data); err != nil {
		return false, err
	}
	warn(fmt.Sprintf("devzone : state restored from the backup copy: %s (confirm with devzone apply)", s.path))
	_ = s.RecoveryMark()
	return true, nil
}

// writeDefaultLocked writes the first-install default state.
func (s *State) writeDefaultLocked() error {
	return s.replaceBytesLocked([]byte("ai=off\nkubernetes=off\ngitlab=off\n"))
}
