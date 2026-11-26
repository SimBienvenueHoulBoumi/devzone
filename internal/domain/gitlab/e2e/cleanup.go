package e2e

import (
	"fmt"
	"os"
)

// cleanup is the equivalent of the shell EXIT trap: the throwaway key is
// removed, the previous platform restored and the temporary folders deleted,
// even when a step failed.
func (s *session) cleanup() {
	s.deleteKey()
	if s.changed {
		_ = s.restorePlatform()
	}
	for _, dir := range s.tempDirs {
		_ = os.RemoveAll(dir)
	}
	s.tempDirs = nil
}

// restorePlatform returns to the platform chosen before the test: the GitLab
// instance with its URL, or github by default.
func (s *session) restorePlatform() error {
	args := []string{"platform", "github"}
	if s.platform == "gitlab" && s.urlBefore != "" {
		args = []string{"platform", "gitlab", "--url", s.urlBefore}
	}
	res, err := s.run(s.devzone, args)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("platform restore code %d", res.Code)
	}
	return nil
}
