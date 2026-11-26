package ai

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// repowardenCommands are the hook commands removed with the guard.
var repowardenCommands = []string{"repowarden garde", "repowarden guard"}

// hasRepowardenHook reports whether a hook array calls the repowarden guard.
func hasRepowardenHook(hooks []any) bool {
	for _, entry := range hooks {
		if m, ok := entry.(map[string]any); ok {
			if command, ok := m["command"].(string); ok && mentionsRepowarden(command) {
				return true
			}
			if inner, ok := m["hooks"].([]any); ok && hasRepowardenHook(inner) {
				return true
			}
		}
	}
	return false
}

// mentionsRepowarden reports whether a hook command calls the repowarden guard.
func mentionsRepowarden(command string) bool {
	for _, text := range repowardenCommands {
		if strings.Contains(command, text) {
			return true
		}
	}
	return false
}

// removeRepowardenHooks drops only the repowarden hook commands, keeping the
// rest of the settings file.
func removeRepowardenHooks(o Options) error {
	path := settingsFile(o.home())
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	doc := map[string]any{}
	if json.Unmarshal(data, &doc) != nil {
		return nil
	}
	hooks, ok := doc["hooks"].(map[string]any)
	if !ok {
		return nil
	}
	pre, ok := hooks["PreToolUse"].([]any)
	if !ok || !hasRepowardenHook(pre) {
		return nil
	}
	pre = filterRepowarden(pre)
	if len(pre) == 0 {
		delete(hooks, "PreToolUse")
	} else {
		hooks["PreToolUse"] = pre
	}
	if len(hooks) == 0 {
		delete(doc, "hooks")
	} else {
		doc["hooks"] = hooks
	}
	return writeSettings(o, path, doc)
}

// filterRepowarden removes the repowarden entries of one hook array.
func filterRepowarden(hooks []any) []any {
	var out []any
	for _, entry := range hooks {
		m, ok := entry.(map[string]any)
		if !ok {
			out = append(out, entry)
			continue
		}
		if command, ok := m["command"].(string); ok && mentionsRepowarden(command) {
			continue
		}
		if inner, ok := m["hooks"].([]any); ok {
			filtered := filterRepowarden(inner)
			if len(filtered) == 0 {
				continue
			}
			m["hooks"] = filtered
		}
		out = append(out, m)
	}
	return out
}

// removeRepowardenPlugins removes the two plugins installed by repowarden.
func removeRepowardenPlugins(o Options) {
	dst := filepath.Join(o.home(), ".config", "opencode", "plugins")
	for _, name := range []string{"repowarden-garde.js", "repowarden-garde-v2.js"} {
		os.Remove(filepath.Join(dst, name))
	}
}
