// Package state reads and writes the .devzone.modules file (key=value lines),
// keeping unknown lines in order and guarding writes with a directory lock.
package state

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// State is a handle on a .devzone.modules file.
type State struct {
	path    string
	depth   int
	flockFd *os.File
	op      sync.Mutex
	mu      sync.Mutex
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
	s.op.Lock()
	defer s.op.Unlock()
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.setLocked(key, value)
}

// Delete removes every line for key, keeping the other lines in order.
func (s *State) Delete(key string) error {
	s.op.Lock()
	defer s.op.Unlock()
	if err := s.lock(); err != nil {
		return err
	}
	defer s.unlock()
	return s.deleteLocked(key)
}

// Package-level helpers for callers that prefer a path argument.
func Get(location, key string) string       { return New(location).Get(key) }
func Set(location, key, value string) error { return New(location).Set(key, value) }
func Delete(location, key string) error     { return New(location).Delete(key) }
