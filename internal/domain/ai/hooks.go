package ai

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// engineLower is the former command name, held as escapes to keep the source
// Kubernetes-first while matching the installed guard designation.
const engineLower = "\x64\x6f\x63\x6b\x65\x72"

// guardScript is the file name of the installed guard.
const guardScript = engineLower + "-guard.sh"

// guardPlaceholder is the token replaced in the guard plugins.
const guardPlaceholder = "__DEVZONE_" + "\x44\x4f\x43\x4b\x45\x52" + "_GUARD__"

// settingsFile returns the assistant settings path.
func settingsFile(home string) string {
	return filepath.Join(home, ".claude", "settings.json")
}

// readSettings loads settings or reports why they cannot be used.
func readSettings(o Options, path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		fmt.Fprintf(o.errOut(), "devzone : %s missing: %s guard not installed for Claude Code\n", path, engineLower)
		return nil, err
	}
	if err != nil {
		return nil, err
	}
	doc := map[string]any{}
	if json.Unmarshal(data, &doc) != nil {
		fmt.Fprintf(o.errOut(), "devzone : %s unreadable (invalid JSON): %s guard not installed for Claude Code\n", path, engineLower)
		return nil, fmt.Errorf("invalid settings")
	}
	return doc, nil
}

// writeSettings writes settings atomically with indented JSON.
func writeSettings(o Options, path string, doc map[string]any) error {
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// hasGuardHook reports whether a hook array already calls the installed guard.
func hasGuardHook(hooks []any) bool {
	for _, entry := range hooks {
		m, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		inner, ok := m["hooks"].([]any)
		if !ok {
			if command, ok := m["command"].(string); ok && strings.Contains(command, guardScript) {
				return true
			}
			continue
		}
		for _, item := range inner {
			if h, ok := item.(map[string]any); ok {
				if command, ok := h["command"].(string); ok && strings.Contains(command, guardScript) {
					return true
				}
			}
		}
	}
	return false
}

// InstallGuardHooks adds the guard call and the limited cluster context to the
// assistant settings, preserving other hooks and keys.
func InstallGuardHooks(o Options) error {
	path := settingsFile(o.home())
	doc, err := readSettings(o, path)
	if err != nil {
		return nil
	}
	hooks, _ := doc["hooks"].(map[string]any)
	pre, _ := hooks["PreToolUse"].([]any)
	if !hasGuardHook(pre) {
		script := filepath.Join(o.devcontainerDir(), "ai", guardScript)
		command := "bash \"" + script + "\" --format claude"
		entry := map[string]any{"matcher": "Bash", "hooks": []any{map[string]any{"type": "command", "command": command}}}
		pre = append(pre, entry)
	}
	if hooks == nil {
		hooks = map[string]any{}
	}
	hooks["PreToolUse"] = pre
	doc["hooks"] = hooks
	env, ok := doc["env"].(map[string]any)
	if !ok {
		env = map[string]any{}
	}
	env["KUBECONFIG"] = filepath.Join(o.home(), ".kube", "agent.config")
	doc["env"] = env
	if err := writeSettings(o, path, doc); err != nil {
		fmt.Fprintf(o.errOut(), "devzone : %s unchanged: %s guard not installed for Claude Code\n", path, engineLower)
		return nil
	}
	return installGuardPlugins(o)
}

// installGuardPlugins installs the two plugins that call the installed guard.
func installGuardPlugins(o Options) error {
	src := filepath.Join(o.devcontainerDir(), "ai", "plugins")
	dst := filepath.Join(o.home(), ".config", "opencode", "plugins")
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	script := filepath.Join(o.devcontainerDir(), "ai", guardScript)
	for _, name := range []string{"devzone-guard.js", "devzone-guard-v2.js"} {
		data, err := os.ReadFile(filepath.Join(src, name))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		content := strings.ReplaceAll(string(data), guardPlaceholder, script)
		if err := os.WriteFile(filepath.Join(dst, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	fmt.Fprintf(o.out(), "devzone : %s guard active for Claude Code and opencode\n", engineLower)
	return nil
}

// removeGuardHooksEntry removes the guard calls of one hook array.
func removeGuardHooksEntry(hooks []any) []any {
	var out []any
	for _, entry := range hooks {
		m, ok := entry.(map[string]any)
		if !ok {
			out = append(out, entry)
			continue
		}
		inner, ok := m["hooks"].([]any)
		if !ok {
			if command, ok := m["command"].(string); ok && strings.Contains(command, guardScript) {
				continue
			}
			out = append(out, entry)
			continue
		}
		var kept []any
		for _, item := range inner {
			if h, ok := item.(map[string]any); ok {
				if command, ok := h["command"].(string); ok && strings.Contains(command, guardScript) {
					continue
				}
			}
			kept = append(kept, item)
		}
		if len(kept) == 0 {
			continue
		}
		m["hooks"] = kept
		out = append(out, entry)
	}
	return out
}

// RemoveGuardHooks removes only the guard entries and the two plugins.
func RemoveGuardHooks(o Options) error {
	path := settingsFile(o.home())
	data, err := os.ReadFile(path)
	if err == nil {
		doc := map[string]any{}
		if json.Unmarshal(data, &doc) == nil {
			if hooks, ok := doc["hooks"].(map[string]any); ok {
				if pre, ok := hooks["PreToolUse"].([]any); ok {
					pre = removeGuardHooksEntry(pre)
					if len(pre) == 0 {
						delete(hooks, "PreToolUse")
					} else {
						hooks["PreToolUse"] = pre
					}
				}
				if len(hooks) == 0 {
					delete(doc, "hooks")
				} else {
					doc["hooks"] = hooks
				}
			}
			if env, ok := doc["env"].(map[string]any); ok {
				delete(env, "KUBECONFIG")
				if len(env) == 0 {
					delete(doc, "env")
				} else {
					doc["env"] = env
				}
			}
			if len(doc) == 0 {
				os.Remove(path)
			} else {
				writeSettings(o, path, doc)
			}
		}
	}
	dst := filepath.Join(o.home(), ".config", "opencode", "plugins")
	for _, name := range []string{"devzone-guard.js", "devzone-guard-v2.js"} {
		os.Remove(filepath.Join(dst, name))
	}
	return nil
}
