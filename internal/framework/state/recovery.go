package state

import (
	"os"
	"strconv"
	"time"
)

// recoveryPath returns the marker file written after a restore or rebuild.
func (s *State) recoveryPath() string { return s.path + ".recouvre" }

// RecoveryMark writes the recovery marker so watchers wait before applying.
func (s *State) RecoveryMark() error {
	return os.WriteFile(s.recoveryPath(), []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o644)
}

// RecoveryWait reports whether the recovery marker is younger than 60 seconds.
func (s *State) RecoveryWait() bool {
	age, ok := s.recoveryAge()
	return ok && age < 60*time.Second
}

// RecoveryPending reports whether a recovery marker exists and is still waiting for confirmation.
func (s *State) RecoveryPending() bool {
	_, err := os.Stat(s.recoveryPath())
	return err == nil
}

// RecoveryConfirm removes the recovery marker after the user confirms the state.
func (s *State) RecoveryConfirm() error {
	err := os.Remove(s.recoveryPath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// recoveryAge returns the age of the recovery marker.
func (s *State) recoveryAge() (time.Duration, bool) {
	data, err := os.ReadFile(s.recoveryPath())
	if err != nil {
		return 0, false
	}
	sec, err := strconv.ParseInt(stringsTrim(string(data)), 10, 64)
	if err != nil {
		return 0, false
	}
	return time.Since(time.Unix(sec, 0)), true
}

// stringsTrim trims spaces and newlines from marker content.
func stringsTrim(v string) string {
	for len(v) > 0 {
		c := v[len(v)-1]
		if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
			v = v[:len(v)-1]
			continue
		}
		break
	}
	for len(v) > 0 {
		c := v[0]
		if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
			v = v[1:]
			continue
		}
		break
	}
	return v
}
