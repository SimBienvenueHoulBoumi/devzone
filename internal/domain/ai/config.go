package ai

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// opencodeMarker identifies the default configuration written by devzone.
const opencodeMarker = "// devzone : default opencode configuration"

// opencodeFile returns the configuration path in use, or the default one.
func opencodeFile(home string) string {
	for _, name := range []string{"opencode.jsonc", "opencode.json"} {
		path := filepath.Join(home, ".config", "opencode", name)
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return filepath.Join(home, ".config", "opencode", "opencode.jsonc")
}

// opencodeMarked reports whether the file carries the default marker.
func opencodeMarked(path string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(data), opencodeMarker)
}

// onlySchema reports whether a file holds nothing but the schema key.
func onlySchema(data string) bool {
	found := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed == "{" || trimmed == "}" {
			continue
		}
		if strings.Contains(trimmed, "$schema") {
			found = true
			continue
		}
		return false
	}
	return found
}

// copyOpencode writes the model to the target and announces the change.
func copyOpencode(o Options, model, target, message string) error {
	data, err := os.ReadFile(model)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(target, data, 0o644); err != nil {
		return err
	}
	fmt.Fprintln(o.out(), message)
	return nil
}

// InstallOpencodeConfig writes the default configuration when missing, updates
// it while marked, and keeps a customised one.
func InstallOpencodeConfig(o Options) error {
	model := filepath.Join(o.devcontainerDir(), "opencode.jsonc")
	target := opencodeFile(o.home())
	if _, err := os.Stat(target); os.IsNotExist(err) {
		return copyOpencode(o, model, target, "opencode : default configuration written")
	}
	if opencodeMarked(target) {
		original, err := os.ReadFile(model)
		if err != nil {
			return err
		}
		current, err := os.ReadFile(target)
		if err != nil {
			return err
		}
		if string(original) != string(current) {
			return copyOpencode(o, model, target, "opencode : default configuration updated")
		}
		return nil
	}
	current, err := os.ReadFile(target)
	if err != nil {
		return err
	}
	if onlySchema(string(current)) {
		return copyOpencode(o, model, target, "opencode : default configuration updated")
	}
	fmt.Fprintln(o.out(), "opencode : custom configuration, kept")
	return nil
}

// RemoveOpencodeConfig removes the default configuration only when it is still
// marked and unchanged; a customised one is kept.
func RemoveOpencodeConfig(o Options) error {
	target := opencodeFile(o.home())
	if _, err := os.Stat(target); os.IsNotExist(err) {
		return nil
	}
	if !opencodeMarked(target) {
		fmt.Fprintln(o.out(), "opencode : custom configuration, kept")
		return nil
	}
	model, err := os.ReadFile(filepath.Join(o.devcontainerDir(), "opencode.jsonc"))
	if err != nil {
		return err
	}
	current, err := os.ReadFile(target)
	if err != nil {
		return err
	}
	if string(model) == string(current) {
		if err := os.Remove(target); err != nil {
			return err
		}
		fmt.Fprintln(o.out(), "opencode : default configuration removed")
		return nil
	}
	fmt.Fprintln(o.out(), "opencode : custom configuration, kept")
	return nil
}
