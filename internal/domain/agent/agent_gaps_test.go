package agent

import (
	"context"
	"os"
	"strings"
	"testing"
)

// agent-gaps: causes, network, silent, frozen, no free model.
func TestAgentAllModelsExcluded(t *testing.T) {
	s := newSandbox(t)
	os.MkdirAll(s.state, 0o755)
	// exclude all models
	for _, m := range FreeModelsDefault {
		os.WriteFile(s.state+"/ecart-"+m, []byte("9999999999 quota 3600\n"), 0o644)
	}
	code := AgentLaunch(context.Background(), s.opts(), s.proj, s.brief)
	if code != 3 {
		t.Fatal("code", code)
	}
	if !strings.Contains(readFileString(s.journal()), "no free model available") {
		t.Fatal("no msg", readFileString(s.journal()))
	}
}

func TestAgentUnknownCauseNoExclusion(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$modele" = big-pickle ]; then
  echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR message=\"stream error\" modelID=$modele error=AI_APICallError: Model is unavailable" >&2
  exit 1
fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if len(modelsLaunched()) < 2 || modelsLaunched()[1] != "deepseek-v4.1-flash-free" {
		t.Fatal("next model", modelsLaunched())
	}
	if fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("excluded on autre")
	}
	if !strings.Contains(readFileString(s.journal()), "no exclusion") {
		t.Fatal("no exclusion msg", readFileString(s.journal()))
	}
}

func TestAgentNetworkWordButReachable(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$modele" = big-pickle ]; then
  echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR message=\"stream error\" modelID=$modele error=AI_APICallError: network down" >&2
  exit 1
fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	// network reachable (fake getent+curl exit 0)
	os.WriteFile(s.bin+"/getent", []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755)
	os.WriteFile(s.bin+"/curl", []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "network reachable: treated as other") {
		t.Fatal("no treated as other", j)
	}
	if fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("excluded")
	}
}

// TestAgentNetworkUnavailable checks that a permanent network error returns
// code 4 without excluding the model, as the removed agent-gaps.bats did.
func TestAgentNetworkUnavailable(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR message=\"stream error\" modelID=$modele error=AI_APICallError: ENOTFOUND" >&2
exit 1
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	t.Setenv("DEVZONE_AGENT_NETWORK_MAX", "1")
	t.Setenv("DEVZONE_AGENT_NETWORK_STEP", "1")
	if code := AgentLaunch(context.Background(), s.opts(), s.proj, s.brief); code != 4 {
		t.Fatal("code", code)
	}
	if !strings.Contains(readFileString(s.journal()), "network unavailable") {
		t.Fatal("no network unavailable", readFileString(s.journal()))
	}
	if fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("excluded on network")
	}
}

func TestAgentSilentAtStart(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$modele" = big-pickle ]; then sleep 30; exit 0; fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	t.Setenv("DEVZONE_AGENT_SILENCE", "1")
	t.Setenv("DEVZONE_AGENT_STEP", "0.1")
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if !strings.Contains(readFileString(s.journal()), "silent at start") {
		t.Fatal("no silent", readFileString(s.journal()))
	}
	if !strings.Contains(readFileString(s.state+"/ecart-big-pickle"), "mute 3600") {
		t.Fatal("no mute exclusion", readFileString(s.state+"/ecart-big-pickle"))
	}
}

func TestAgentFrozenSession(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$#" -gt 0 ]; then consigne="${!#}"; else consigne=""; fi
printf '%s\n---\n' "$consigne" >>"$FAKE_OP_CONSIGNE_LOG"
if [ "$modele" = big-pickle ]; then echo "starting"; sleep 30; exit 0; fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	t.Setenv("DEVZONE_AGENT_SILENCE", "2")
	t.Setenv("DEVZONE_AGENT_FROZEN", "1")
	t.Setenv("DEVZONE_AGENT_STEP", "0.1")
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "frozen") {
		t.Fatal("no frozen", j)
	}
	if !strings.Contains(readFileString(os.Getenv("FAKE_OP_CONSIGNE_LOG")), "RESUME") {
		t.Fatal("no resume", readFileString(os.Getenv("FAKE_OP_CONSIGNE_LOG")))
	}
}
