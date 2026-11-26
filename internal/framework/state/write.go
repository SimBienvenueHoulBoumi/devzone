package state

import (
	"os"
	"strings"
)

// Replace atomically replaces the whole state with the content of src, keeping
// a backup copy of the previous state. It is the only whole-file write path.
func (s *State) Replace(src string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.replaceBytesLocked(data)
}

// ReplaceBytes atomically replaces the whole state with data and backs up the
// previous state, used by init and rebuild.
func (s *State) ReplaceBytes(data []byte) error {
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.replaceBytesLocked(data)
}

// replaceBytesLocked writes data to a temp file in the state directory, backs up
// the previous state, then renames. The temp file stays in the same directory so
// the rename is atomic and readers never see a missing or partial state.
func (s *State) replaceBytesLocked(data []byte) error {
	if err := s.backupLocked(); err != nil {
		return err
	}
	return s.atomicWrite(data)
}

// atomicWrite writes data to a temp file beside the state file then renames it.
func (s *State) atomicWrite(data []byte) error {
	tmp, err := os.CreateTemp(s.Dir(), ".devzone.modules.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(name)
	}
	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(name)
		return err
	}
	if err := os.Rename(name, s.path); err != nil {
		_ = os.Remove(name)
		return err
	}
	return nil
}

// backupLocked copies the current state to .prev before a replacement.
func (s *State) backupLocked() error {
	data, err := os.ReadFile(s.path)
	if err == nil {
		return os.WriteFile(s.prevPath(), data, 0o644)
	}
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// prevPath returns the backup copy path written before each replacement.
func (s *State) prevPath() string { return s.path + ".prev" }

// setLocked backs up, filters the key, appends key=value, and renames.
func (s *State) setLocked(key, value string) error {
	if err := s.backupLocked(); err != nil {
		return err
	}
	lines, err := s.filteredLines(key)
	if err != nil {
		return err
	}
	lines = append(lines, key+"="+value)
	return s.atomicWrite([]byte(strings.Join(lines, "\n") + "\n"))
}

// deleteLocked removes key while holding the lock; a missing state is a no-op.
func (s *State) deleteLocked(key string) error {
	if _, err := os.Stat(s.path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	if err := s.backupLocked(); err != nil {
		return err
	}
	lines, err := s.filteredLines(key)
	if err != nil {
		return err
	}
	if len(lines) == 0 {
		return s.atomicWrite(nil)
	}
	return s.atomicWrite([]byte(strings.Join(lines, "\n") + "\n"))
}

// filteredLines returns state lines except those starting with key=, preserving order.
func (s *State) filteredLines(key string) ([]string, error) {
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	prefix := key + "="
	text := strings.TrimSuffix(string(data), "\n")
	if len(text) == 0 && len(data) == 0 {
		return nil, nil
	}
	raw := strings.Split(text, "\n")
	out := make([]string, 0, len(raw))
	for _, line := range raw {
		if strings.HasPrefix(line, prefix) {
			continue
		}
		out = append(out, line)
	}
	return out, nil
}
