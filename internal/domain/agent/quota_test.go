package agent

import (
	"context"
	"os"
	"strings"
	"testing"
)

// agent-quota: quota/country recognized right away in wait loop (#367).
func TestAgentQuotaRecognizedRightAway(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
echo "$*" >>"$FAKE_OP_ARGS_LOG"
if [ "$modele" = big-pickle ]; then
  echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR run=x message=stream error providerID=opencode modelID=$modele error=AI_APICallError: Free usage limit" >&2
  sleep 30; exit 0
fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	os.Setenv("FAKE_OP_ARGS_LOG", s.root+"/args.log")
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	ms := modelsLaunched()
	if len(ms) != 2 || ms[0] != "big-pickle" || ms[1] != "deepseek-v4.1-flash-free" {
		t.Fatal("not excluded next", ms)
	}
	if !strings.Contains(readFileString(s.state+"/ecart-big-pickle"), "quota 3600") {
		t.Fatal("no exclusion", readFileString(s.state+"/ecart-big-pickle"))
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "excluded (quota): next model") {
		t.Fatal("no excluded", j)
	}
	// --print-logs --log-level ERROR
	if !strings.Contains(readFileString(s.root+"/args.log"), "--print-logs --log-level ERROR") {
		t.Fatal("no print-logs", readFileString(s.root+"/args.log"))
	}
}

func TestAgentCountryRecognizedRightAway(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$modele" = big-pickle ]; then
  echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR run=x message=process session.id=x error=This model is not available in your country stack=opencode" >&2
  sleep 30; exit 0
fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if !strings.Contains(readFileString(s.state+"/ecart-big-pickle"), "pays 604800") {
		t.Fatal("no country exclusion", readFileString(s.state+"/ecart-big-pickle"))
	}
	if !strings.Contains(readFileString(s.journal()), "excluded (country): next model") {
		t.Fatal("no excluded", readFileString(s.journal()))
	}
}

func TestAgentOrdinaryTextNoExclusion(t *testing.T) {
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\n'; exit 0; fi
echo big-pickle >>"$FAKE_OP_LOG"
echo "code excerpt: Free usage limit and not available in your country"
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if len(modelsLaunched()) != 1 {
		t.Fatal("more than one", modelsLaunched())
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "end with opencode/big-pickle") || strings.Contains(j, "excluded") {
		t.Fatal("ordinary text triggered", j)
	}
	if fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("exclusion created")
	}
}
