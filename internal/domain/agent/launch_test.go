package agent

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestAgentLaunchEndWith(t *testing.T) {
	s := newSandbox(t)
	code := AgentLaunch(context.Background(), s.opts(), s.proj, s.brief)
	if code != 0 {
		t.Fatal("code", code)
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "end with opencode/big-pickle") {
		t.Fatal("no end with", j)
	}
	if !strings.Contains(opLog(), "big-pickle") {
		t.Fatal("no model launched")
	}
	if !strings.Contains(readFileString(os.Getenv("FAKE_OP_CONSIGNE_LOG")), "construis la feature") {
		t.Fatal("brief not read")
	}
	if !strings.Contains(j, "=== --model : none") || !strings.Contains(j, "=== rank 1/") {
		t.Fatal("headers", j)
	}
	// OPENCODE_CONFIG_CONTENT safe
	cfg := readFileString(os.Getenv("FAKE_OP_CONFIG_LOG"))
	if !strings.Contains(cfg, `"git push*":"deny"`) {
		t.Fatal("config not safe", cfg)
	}
}

func TestAgentLaunchFolderBriefNotFound(t *testing.T) {
	s := newSandbox(t)
	if code := AgentLaunch(context.Background(), s.opts(), s.root+"/absent", s.brief); code != 2 {
		t.Fatal("folder code", code)
	}
	if code := AgentLaunch(context.Background(), s.opts(), s.proj, s.root+"/nope.txt"); code != 2 {
		t.Fatal("brief code", code)
	}
	if fileExists(s.state) {
		t.Fatal("state created on refusal")
	}
}

func TestAgentLaunchAiDisabled(t *testing.T) {
	s := newSandbox(t)
	os.WriteFile(s.dc+"/devzone", []byte("#!/usr/bin/env bash\nexit 1\n"), 0o755)
	if code := AgentLaunch(context.Background(), s.opts(), s.proj, s.brief); code != 2 {
		t.Fatal("code", code)
	}
	if opLog() != "" {
		t.Fatal("opencode launched when ai disabled")
	}
}

func TestAgentLaunchTwoLaunchesDifferentModels(t *testing.T) {
	s := newSandbox(t)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("first")
	}
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("second")
	}
	ms := modelsLaunched()
	if len(ms) != 2 || ms[0] == ms[1] {
		t.Fatal("two different models", ms)
	}
}

func TestAgentLaunchModelFlag(t *testing.T) {
	s := newSandbox(t)
	o := s.opts()
	o.ModelList = "hy4-flash-free"
	if AgentLaunch(context.Background(), o, s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if modelsLaunched()[0] != "hy4-flash-free" {
		t.Fatal("requested not first", modelsLaunched())
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "=== requested model chosen: hy4-flash-free") {
		t.Fatal("no chosen", j)
	}
	if !strings.Contains(j, "=== --model : hy4-flash-free") {
		t.Fatal("no model header", j)
	}
}

func TestAgentLaunchUnknownModel(t *testing.T) {
	s := newSandbox(t)
	o := s.opts()
	o.ModelList = "inconnu-free"
	if AgentLaunch(context.Background(), o, s.proj, s.brief) != 2 {
		t.Fatal("code")
	}
	if opLog() != "" {
		t.Fatal("launched unknown model")
	}
}

func TestAgentLaunchModelRequestedExcluded(t *testing.T) {
	s := newSandbox(t)
	os.MkdirAll(s.state, 0o755)
	os.WriteFile(s.state+"/ecart-hy4-flash-free", []byte("9999999999 quota 3600\n"), 0o644)
	o := s.opts()
	o.ModelList = "hy4-flash-free,beam-free"
	if AgentLaunch(context.Background(), o, s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if modelsLaunched()[0] != "beam-free" {
		t.Fatal("excluded requested first", modelsLaunched())
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "=== requested model hy4-flash-free excluded (quota), next") {
		t.Fatal("no excluded line", j)
	}
}

func TestAgentLaunchOldMuetCounted(t *testing.T) {
	s := newSandbox(t)
	os.MkdirAll(s.state, 0o755)
	os.WriteFile(s.state+"/muet-big-pickle", []byte("9999999999\n"), 0o644)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	if modelsLaunched()[0] != "deepseek-v4.1-flash-free" {
		t.Fatal("muet not counted", modelsLaunched())
	}
}

func TestAgentLaunchRelativePaths(t *testing.T) {
	s := newSandbox(t)
	// relative folder + brief resolved from calling folder
	os.MkdirAll(s.root+"/workspace/projet", 0o755)
	old, _ := os.Getwd()
	os.Chdir(s.root)
	defer os.Chdir(old)
	code := AgentLaunch(context.Background(), s.opts(), "workspace/projet", "workspace/consigne.txt")
	if code != 0 {
		t.Fatal("code", code)
	}
	if !strings.Contains(readFileString(os.Getenv("FAKE_OP_CONSIGNE_LOG")), "construis la feature") {
		t.Fatal("relative brief not read")
	}
}

func TestAgentLaunchSessionFatalQuota(t *testing.T) {
	// fake opencode emitting quota error line then sleeping; should kill + exclude + next
	s := newSandbox(t)
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\n'; exit 0; fi
modele=""; for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
echo "$modele" >>"$FAKE_OP_LOG"
if [ "$modele" = big-pickle ]; then
  echo "timestamp=2024-01-01T00:00:00.000Z level=ERROR run=x message=\"stream error\" providerID=opencode modelID=$modele error=\"AI_APICallError: Free usage limit\"" >&2
  sleep 30; exit 0
fi
echo ok; exit 0
`
	os.WriteFile(s.bin+"/opencode", []byte(opencode), 0o755)
	if AgentLaunch(context.Background(), s.opts(), s.proj, s.brief) != 0 {
		t.Fatal("code")
	}
	ms := modelsLaunched()
	if len(ms) < 2 || ms[0] != "big-pickle" || ms[1] != "deepseek-v4.1-flash-free" {
		t.Fatal("not excluded next", ms)
	}
	j := readFileString(s.journal())
	if !strings.Contains(j, "excluded (quota): next model") {
		t.Fatal("no excluded", j)
	}
	if !fileExists(s.state + "/ecart-big-pickle") {
		t.Fatal("no exclusion file")
	}
}
