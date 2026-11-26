package ai

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// skillMarker is the marker written in the installed skill file.
const skillMarker = "<!-- devzone : skill set by devzone enable ai -->"

// skillFingerprint is the name of the file recording the installed checksum.
const skillFingerprint = ".devzone-fingerprint"

// skillDirs returns the assistant skill folders in the user volumes.
func skillDirs(home string) []string {
	return []string{
		filepath.Join(home, ".claude", "skills", "devzone"),
		filepath.Join(home, ".config", "opencode", "skills", "devzone"),
	}
}

// checksum returns the lowercase sha256 of a file.
func checksum(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

// hasSkillMarker reports whether a skill file carries the devzone marker.
func hasSkillMarker(data []byte) bool { return strings.Contains(string(data), skillMarker) }

// skillUnchanged reports whether the installed skill still matches its
// fingerprint, or its model when no fingerprint was recorded.
func skillUnchanged(target, fingerprint, model string) bool {
	data, err := os.ReadFile(target)
	if err != nil {
		return false
	}
	if fingerprint != "" {
		sum, err := checksum(target)
		return err == nil && sum == fingerprint
	}
	original, err := os.ReadFile(model)
	return err == nil && string(original) == string(data)
}

// savedFingerprint reads the recorded checksum of one skill folder.
func savedFingerprint(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, skillFingerprint))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// recordFingerprint writes the checksum of the installed skill.
func recordFingerprint(dir, target string) error {
	sum, err := checksum(target)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, skillFingerprint), []byte(sum+"\n"), 0o644)
}

// InstallSkill writes the skill where missing, updates it while marked and
// unchanged, and keeps a customised one.
func InstallSkill(o Options, model string) error {
	data, err := os.ReadFile(model)
	if err != nil {
		return err
	}
	for _, dir := range skillDirs(o.home()) {
		target := filepath.Join(dir, "SKILL.md")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		if _, err := os.Stat(target); os.IsNotExist(err) {
			if err := os.WriteFile(target, data, 0o644); err != nil {
				return err
			}
			if err := recordFingerprint(dir, target); err != nil {
				return err
			}
			fmt.Fprintf(o.out(), "devzone : devzone skill installed in %s\n", dir)
			continue
		}
		installed, err := os.ReadFile(target)
		if err != nil {
			return err
		}
		if hasSkillMarker(installed) && skillUnchanged(target, savedFingerprint(dir), model) {
			if string(installed) != string(data) {
				if err := os.WriteFile(target, data, 0o644); err != nil {
					return err
				}
				fmt.Fprintf(o.out(), "devzone : devzone skill updated in %s\n", dir)
			}
			if err := recordFingerprint(dir, target); err != nil {
				return err
			}
		} else {
			fmt.Fprintf(o.out(), "devzone : customised devzone skill in %s, kept\n", dir)
		}
	}
	return nil
}

// RemoveSkill removes the skill where it is still the installed one, and
// keeps a customised one.
func RemoveSkill(o Options, model string) error {
	for _, dir := range skillDirs(o.home()) {
		target := filepath.Join(dir, "SKILL.md")
		installed, err := os.ReadFile(target)
		if os.IsNotExist(err) {
			os.Remove(filepath.Join(dir, skillFingerprint))
			continue
		}
		if err != nil {
			return err
		}
		if hasSkillMarker(installed) && skillUnchanged(target, savedFingerprint(dir), model) {
			if err := os.Remove(target); err != nil {
				return err
			}
			os.Remove(filepath.Join(dir, skillFingerprint))
			fmt.Fprintf(o.out(), "devzone : devzone skill removed from %s\n", dir)
		} else {
			fmt.Fprintf(o.out(), "devzone : customised devzone skill in %s, kept\n", dir)
		}
	}
	return nil
}
