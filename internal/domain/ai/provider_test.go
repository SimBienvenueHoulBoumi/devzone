package ai

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeConfigFile writes a configuration in the disposable home.
func writeConfigFile(t *testing.T, f fixture, data string) {
	t.Helper()
	path := configPath(f.o)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// readConfigFile returns the current configuration content.
func readConfigFile(t *testing.T, f fixture) string {
	t.Helper()
	data, err := os.ReadFile(configPath(f.o))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// TestSetProviderMerges checks that the host provider is added and the rest kept.
func TestSetProviderMerges(t *testing.T) {
	f := newFixture(t)
	f.tags(threeModels)
	writeConfigFile(t, f, `{"model":"x/y","provider":{"autre":{"name":"a"}}}`)
	if err := SetProvider(ctx(), f.o); err != nil {
		t.Fatal(err)
	}
	doc := map[string]any{}
	decodeConfig(t, readConfigFile(t, f), &doc)
	provider := doc["provider"].(map[string]any)
	host := provider["devzone-host"].(map[string]any)
	if host["npm"] != "@ai-sdk/openai-compatible" || doc["model"] != "x/y" || provider["autre"] == nil {
		t.Fatalf("merged config = %v", doc)
	}
	if host["options"].(map[string]any)["baseURL"] != f.o.url()+"/v1" {
		t.Fatalf("baseURL = %v", host["options"])
	}
	models := host["models"].(map[string]any)
	if len(models) != 2 || models["qwen3-coder:32k"] == nil {
		t.Fatalf("models = %v", models)
	}
}

// TestSetProviderInvalidJSONLeavesFile checks that a bad configuration is kept.
func TestSetProviderInvalidJSONLeavesFile(t *testing.T) {
	f := newFixture(t)
	f.tags(threeModels)
	writeConfigFile(t, f, "{ nope")
	if err := SetProvider(ctx(), f.o); err == nil {
		t.Fatal("expected an error")
	}
	if got := readConfigFile(t, f); got != "{ nope" {
		t.Fatalf("file = %q", got)
	}
	if f.err.Len() == 0 {
		t.Fatal("no error message")
	}
}

// TestUnsetProviderKeepsOtherSettings checks that both host providers are
// removed and the file disappears when nothing else remains.
func TestUnsetProviderKeepsOtherSettings(t *testing.T) {
	f := newFixture(t)
	writeConfigFile(t, f, `{"model":"x/y","provider":{"devzone-llm":{"name":"old"},"devzone-host":{"name":"host"},"autre":{"name":"keep"}}}`)
	if err := UnsetProvider(f.o); err != nil {
		t.Fatal(err)
	}
	doc := map[string]any{}
	decodeConfig(t, readConfigFile(t, f), &doc)
	provider := doc["provider"].(map[string]any)
	if len(provider) != 1 || provider["autre"] == nil || doc["model"] != "x/y" {
		t.Fatalf("config = %v", doc)
	}
	writeConfigFile(t, f, `{"provider":{"devzone-host":{"name":"host"}}}`)
	if err := UnsetProvider(f.o); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(configPath(f.o)); !os.IsNotExist(err) {
		t.Fatalf("file still exists: %v", err)
	}
}

// TestUnsetProviderWithoutFileIsSilent checks the no-op case.
func TestUnsetProviderWithoutFileIsSilent(t *testing.T) {
	f := newFixture(t)
	if err := UnsetProvider(f.o); err != nil {
		t.Fatal(err)
	}
	if f.err.Len() != 0 {
		t.Fatalf("err = %q", f.err.String())
	}
}

// decodeConfig parses a configuration file for the assertions.
func decodeConfig(t *testing.T, data string, doc *map[string]any) {
	t.Helper()
	if err := json.Unmarshal([]byte(data), doc); err != nil {
		t.Fatal(err)
	}
}
