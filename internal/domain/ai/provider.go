package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// configPath is the opencode configuration file of the user.
func configPath(o Options) string {
	return filepath.Join(o.home(), ".config", "opencode", "config.json")
}

// readConfig loads the configuration, using an empty object when the file is absent.
func readConfig(o Options) (map[string]any, error) {
	path := configPath(o)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	doc := map[string]any{}
	if json.Unmarshal(data, &doc) != nil {
		return nil, fmt.Errorf("%s is not valid JSON", path)
	}
	return doc, nil
}

// writeConfig saves the configuration, dropping the file when only the schema
// key remains, as the installed jq rewrite did.
func writeConfig(o Options, doc map[string]any) error {
	path := configPath(o)
	empty := len(doc) == 0
	if len(doc) == 1 {
		_, onlySchema := doc["$schema"]
		empty = onlySchema
	}
	if empty {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// SetProvider merges the detected models into the devzone-host provider and
// keeps the rest of the configuration.
func SetProvider(ctx context.Context, o Options) error {
	names := Models(ctx, o)
	if len(names) == 0 {
		return nil
	}
	models := map[string]any{}
	for _, name := range names {
		models[name] = map[string]any{"name": name}
	}
	doc, err := readConfig(o)
	if err != nil {
		return invalidConfig(o, err)
	}
	if _, ok := doc["$schema"]; !ok {
		doc["$schema"] = "https://opencode.ai/config.json"
	}
	provider := map[string]any{}
	if existing, ok := doc["provider"].(map[string]any); ok {
		provider = existing
	}
	provider["devzone-host"] = map[string]any{
		"npm":     "@ai-sdk/openai-compatible",
		"name":    "devzone host models (Ollama)",
		"options": map[string]any{"baseURL": o.url() + "/v1"},
		"models":  models,
	}
	doc["provider"] = provider
	return writeConfig(o, doc)
}

// UnsetProvider removes the host providers and keeps the other configuration.
func UnsetProvider(o Options) error {
	if _, err := os.Stat(configPath(o)); os.IsNotExist(err) {
		return nil
	}
	doc, err := readConfig(o)
	if err != nil {
		return invalidConfig(o, err)
	}
	provider, ok := doc["provider"].(map[string]any)
	if !ok {
		return nil
	}
	delete(provider, "devzone-host")
	delete(provider, "devzone-llm")
	if len(provider) == 0 {
		delete(doc, "provider")
	} else {
		doc["provider"] = provider
	}
	return writeConfig(o, doc)
}

// invalidConfig reports an unusable configuration on the error writer.
func invalidConfig(o Options, err error) error {
	fmt.Fprintf(o.errOut(), "devzone: host: %v: provider not touched\n", err)
	return err
}
