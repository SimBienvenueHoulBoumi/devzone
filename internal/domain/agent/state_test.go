package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestAgentStateText(t *testing.T) {
	racine := t.TempDir()
	state := t.TempDir()
	os.MkdirAll(filepath.Join(racine, "workspace", ".agents"), 0o755)
	j := filepath.Join(racine, "workspace", ".agents", "projet.log")
	os.WriteFile(j, []byte("=== model opencode/big-pickle start 2026-11-06T00:00:00Z\n"), 0o644)
	now := time.Unix(1700000000, 0)
	// exclusion
	os.WriteFile(filepath.Join(state, "ecart-big-pickle"), []byte("1700000000 pays 604800\n"), 0o644)
	out := AgentState(racine, state, now, "", "")
	if !strings.Contains(out, "devzone agent: state") || !strings.Contains(out, "projet.log") || !strings.Contains(out, "opencode/big-pickle") {
		t.Fatal("state", out)
	}
	if !strings.Contains(out, "model big-pickle excluded (country) until") {
		t.Fatal("exclusion", out)
	}
}

func TestAgentStateNoSession(t *testing.T) {
	out := AgentState(t.TempDir(), t.TempDir(), time.Now(), "", "")
	if !strings.Contains(out, "no session") {
		t.Fatal("no session", out)
	}
}

func TestExclusionClear(t *testing.T) {
	state := t.TempDir()
	os.WriteFile(filepath.Join(state, "ecart-a"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(state, "ecart-b"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(state, "muet-a"), []byte("x"), 0o644)
	ExclusionClear(state, "a")
	if fileExists(filepath.Join(state, "ecart-a")) || fileExists(filepath.Join(state, "muet-a")) {
		t.Fatal("a not cleared")
	}
	if !fileExists(filepath.Join(state, "ecart-b")) {
		t.Fatal("b cleared")
	}
	ExclusionClear(state, "--all")
	if fileExists(filepath.Join(state, "ecart-b")) {
		t.Fatal("all not cleared")
	}
}

func TestModelExcluded(t *testing.T) {
	state := t.TempDir()
	now := time.Unix(1700000000, 0)
	os.WriteFile(filepath.Join(state, "ecart-m"), []byte("1700000000 quota 3600\n"), 0o644)
	if !ModelExcluded(state, "m", now) {
		t.Fatal("not excluded")
	}
	if ModelExcluded(state, "m", now.Add(3700*time.Second)) {
		t.Fatal("still excluded")
	}
	// old muet- format timestamp only 1h
	os.WriteFile(filepath.Join(state, "muet-x"), []byte("1700000000\n"), 0o644)
	if !ModelExcluded(state, "x", now) {
		t.Fatal("muet not counted")
	}
	if ModelExcluded(state, "x", now.Add(3700*time.Second)) {
		t.Fatal("muet still counted")
	}
	// default 3600 when no duration
	os.WriteFile(filepath.Join(state, "ecart-y"), []byte("1700000000 quota\n"), 0o644)
	if !ModelExcluded(state, "y", now) {
		t.Fatal("default 3600")
	}
}

// TestAgentStateJSONOtherAgentsInvisible checks that a live session of another
// agent on the machine is neither reported as ours nor matched by our folder.
func TestAgentStateJSONOtherAgentsInvisible(t *testing.T) {
	racine := t.TempDir()
	state := t.TempDir()
	os.MkdirAll(filepath.Join(racine, "workspace", ".agents"), 0o755)
	os.WriteFile(filepath.Join(racine, "workspace", ".agents", "dz-878.log"),
		[]byte("=== model opencode/big-pickle start 2026-11-06T00:00:00Z\n"), 0o644)
	other := "/usr/local/share/devzone/.devcontainer/bin/devzone-pod-linux-amd64 agent --model big-pickle --local /workspaces/projets/dz-879 /consigne.md\n"
	ours := "/usr/local/share/devzone/.devcontainer/bin/devzone-pod-linux-arm64 agent /workspaces/projets/dz-878 /consigne.md\n"
	now := time.Unix(1700000000, 0)
	out := AgentStateJSON(context.Background(), nil, racine, state, other, now)
	if !strings.Contains(out, `"running":false`) {
		t.Fatal("other session reported as ours", out)
	}
	out = AgentStateJSON(context.Background(), nil, racine, state, other+ours, now)
	if !strings.Contains(out, `"running":true`) {
		t.Fatal("our launcher session not seen", out)
	}
}

func TestAgentStateJSON(t *testing.T) {
	racine := t.TempDir()
	state := t.TempDir()
	os.MkdirAll(filepath.Join(racine, "workspace", ".agents"), 0o755)
	os.WriteFile(filepath.Join(racine, "workspace", ".agents", "dz-328.log"), []byte(
		"model text: opencode/agent.json is read\n=== model opencode/beam-free start 2026-11-06T00:00:00Z\nmore text\n=== --model : none\n"), 0o644)
	os.WriteFile(filepath.Join(state, "ecart-big-pickle"), []byte(strconv.FormatInt(time.Now().Unix(), 10)+" pays 604800\n"), 0o644)
	os.WriteFile(filepath.Join(state, "droits-dz-361.alerte"), nil, 0o644)
	out := AgentStateJSON(context.Background(), ExecRunner{}, racine, state, "", time.Now())
	var parsed struct {
		Schema   int `json:"schema"`
		Sessions []struct {
			Journal   string  `json:"journal"`
			Model     string  `json:"model"`
			Start     string  `json:"start"`
			Requested *string `json:"requested"`
			Running   bool    `json:"running"`
		} `json:"sessions"`
		Exclusions []struct {
			Model string `json:"model"`
			Cause string `json:"cause"`
			End   string `json:"end"`
		} `json:"exclusions"`
		RightsAlerts []string `json:"rights_alerts"`
	}
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatal("invalid json", err, out)
	}
	if parsed.Schema != 2 {
		t.Fatal("schema", out)
	}
	if len(parsed.Sessions) != 1 || parsed.Sessions[0].Journal != "dz-328.log" || parsed.Sessions[0].Model != "beam-free" {
		t.Fatal("sessions", out)
	}
	if parsed.Sessions[0].Requested != nil {
		t.Fatal("requested not null", out)
	}
	if len(parsed.Exclusions) != 1 || parsed.Exclusions[0].Cause != "pays" {
		t.Fatal("exclusions", out)
	}
	if len(parsed.RightsAlerts) != 1 || parsed.RightsAlerts[0] != "dz-361" {
		t.Fatal("rights_alerts", out)
	}
}
