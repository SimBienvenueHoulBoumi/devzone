// Package state reads and writes the .devzone.modules file (key=value lines),
// keeping unknown lines in order and guarding writes with a directory lock.
package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// State is a handle on a .devzone.modules file.
type State struct {
	path string
}

// New opens (or creates on write) the state file located in dir, or at path when
// path already points at a .devzone.modules file.
func New(location string) *State {
	path := location
	if !strings.HasSuffix(path, ".devzone.modules") {
		path = filepath.Join(location, ".devzone.modules")
	}
	return &State{path: path}
}

// At returns a handle on exactly this file, whatever its name: DEVZONE_STATE
// names the state file itself, as in the shell.
func At(file string) *State { return &State{path: file} }

// Open is an alias for New.
func Open(location string) *State { return New(location) }

// NewState is an alias for New.
func NewState(location string) *State { return New(location) }

// Load is an alias for New.
func Load(location string) *State { return New(location) }

// Path returns the underlying file path.
func (s *State) Path() string { return s.path }

// Dir returns the directory holding the state file.
func (s *State) Dir() string { return filepath.Dir(s.path) }

// Get returns the value of key, or "" when it is absent.
func (s *State) Get(key string) string {
	v, _ := s.GetOK(key)
	return v
}

// GetOK returns the value of key and whether it was present.
func (s *State) GetOK(key string) (string, bool) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return "", false
	}
	prefix := key + "="
	value := ""
	found := false
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		eq := strings.IndexByte(line, '=')
		value = line[eq+1:]
		found = true
	}
	return value, found
}

// Set writes key=value, removing any previous line for key and keeping the other
// lines (including unknown ones) in their original order.
func (s *State) Set(key, value string) error {
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.writeLocked(key, value, false)
}

// Delete removes every line for key, keeping the other lines in order.
func (s *State) Delete(key string) error {
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.writeLocked(key, "", true)
}

func (s *State) writeLocked(key, value string, delete bool) error {
	prefix := key + "="
	var lines []string
	if data, err := os.ReadFile(s.path); err == nil {
		text := strings.TrimSuffix(string(data), "\n")
		if len(text) > 0 || len(data) > 0 {
			lines = strings.Split(text, "\n")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	var out strings.Builder
	for _, line := range lines {
		if strings.HasPrefix(line, prefix) {
			continue
		}
		out.WriteString(line)
		out.WriteByte('\n')
	}
	if !delete {
		out.WriteString(key)
		out.WriteByte('=')
		out.WriteString(value)
		out.WriteByte('\n')
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, []byte(out.String()), 0o644); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// lock takes the directory lock, waiting briefly for a stale holder.
func (s *State) lock() error {
	dir := s.Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	lock := dir + string(os.PathSeparator) + ".devzone.modules.lock"
	start := time.Now()
	for {
		if err := os.Mkdir(lock, 0o755); err == nil {
			return nil
		} else if !os.IsExist(err) {
			return err
		}
		// stale lock handling
		if info, err := os.Stat(lock); err == nil {
			if time.Since(info.ModTime()) > 30*time.Second {
				_ = os.RemoveAll(lock)
				continue
			}
		}
		if time.Since(start) >= 10*time.Second {
			return fmt.Errorf("state locked: %s", lock)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (s *State) unlock() {
	lock := s.Dir() + string(os.PathSeparator) + ".devzone.modules.lock"
	_ = os.RemoveAll(lock)
}

// Package-level helpers for callers that prefer a path argument.
func Get(location, key string) string       { return New(location).Get(key) }
func Set(location, key, value string) error { return New(location).Set(key, value) }
func Delete(location, key string) error     { return New(location).Delete(key) }
