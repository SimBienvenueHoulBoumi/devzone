package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

// frozenPS is a captured `ps -eo args=` line of a session launched by the old
// shell; the state stays readable after the Go port (#878).
const frozenPS = "/usr/bin/bash /workspaces/devzone/.devcontainer/agent.sh /workspaces/projets/projet /consigne.md\n"

// frozenOutput is the fixed opencode output captured during the comparison.
const frozenOutput = "session big-pickle: instruction read, work starting\n" +
	"the model big-pickle handled the instruction, the matching tests pass\n" +
	"end of session big-pickle: no error, no permission refusal\n"

// frozenResult records the artifacts of a scenario: code, stdout, stderr,
// normalized journal lines and state files.
type frozenResult struct {
	code    int
	out     string
	errOut  string
	journal []string
	state   string
}

// frozenCase links an old shell scenario to the Go test that guards it now.
type frozenCase struct {
	old    string
	goTest string
	run    func(t *testing.T) frozenResult
	want   frozenResult
}

// frozenStarter writes the captured output without launching a process.
type frozenStarter struct{}

// Start emits the captured output and returns an already exited process.
func (frozenStarter) Start(cmd SessionCmd) (SessionProcess, error) {
	fmt.Fprint(cmd.Stdout, frozenOutput)
	return frozenProcess{}, nil
}

// frozenProcess stands for an opencode run that exited successfully.
type frozenProcess struct{}

// Pid returns a fixed pid, so nothing depends on the host process table.
func (frozenProcess) Pid() int { return 123 }

// Alive reports that the captured session has already ended.
func (frozenProcess) Alive() bool { return false }

// Kill does nothing because the captured session has already ended.
func (frozenProcess) Kill() error { return nil }

// Wait returns the captured exit code.
func (frozenProcess) Wait() int { return 0 }

// frozenState renders state files as sorted "name=quoted content" lines.
func frozenState(dir string) string {
	files := globDir(dir, "*")
	sort.Strings(files)
	var b strings.Builder
	for _, f := range files {
		fmt.Fprintf(&b, "%s=%q\n", filepath.Base(f), readFileString(f))
	}
	return b.String()
}

// frozenJournal normalizes only the pid, clock and path of the two lock lines.
func frozenJournal(path string) []string {
	text := readFileString(path)
	if text == "" {
		return nil
	}
	text = regexp.MustCompile(`(?m)^=== lock .*$`).ReplaceAllString(text, "=== lock X")
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

// frozenLaunch runs the Go agent with fake tools and a fixed clock: no real
// waiting, process, cluster or network, and timestamps are reproducible.
func frozenLaunch(t *testing.T, model string, pre map[string]string) (*sandbox, frozenResult) {
	t.Helper()
	s := newSandbox(t)
	for name, content := range pre {
		os.MkdirAll(filepath.Dir(filepath.Join(s.state, name)), 0o755)
		writeFileT(t, filepath.Join(s.state, name), content)
	}
	o := s.opts()
	o.Clock = testClock(t)
	o.ModelList = model
	o.Starter = frozenStarter{}
	var out, errOut strings.Builder
	o.Out, o.Err = &out, &errOut
	code := AgentLaunch(context.Background(), o, s.proj, s.brief)
	return s, frozenResult{code: code, out: out.String(), errOut: errOut.String(),
		journal: frozenJournal(s.journal()), state: frozenState(s.state)}
}

// frozenNormal is the journal of a successful launch with an unrequested model.
var frozenNormal = []string{
	"=== --model : none", "=== lock X", "=== lock X", "=== rank 1/9",
	"=== model opencode/big-pickle start 2023-11-14T22:13:20Z",
	"session big-pickle: instruction read, work starting",
	"the model big-pickle handled the instruction, the matching tests pass",
	"end of session big-pickle: no error, no permission refusal",
	"=== end with opencode/big-pickle (code 0)",
}

// frozenStateLine is the captured text state line of the successful session.
const frozenStateLine = "  session projet.log: model opencode/big-pickle, since 2023-11-14T22:13:20Z, last written 2023-11-14 22:13:20\n"

// frozenStateJSONLine is the captured JSON state of the successful session.
const frozenStateJSONLine = `{"schema":2,"sessions":[{"journal":"projet.log","model":"big-pickle","start":"2023-11-14T22:13:20Z","last_written":"2023-11-14 22:13:20","requested":null,"running":true}],"exclusions":[],"rights_alerts":[]}`

// TestCompareFrozenScenarios replaces the old comparison that read the removed
// shell from git: every old scenario is frozen below and guarded by its Go test.
func TestCompareFrozenScenarios(t *testing.T) {
	fixed := time.Unix(1700000000, 0)
	cases := []frozenCase{
		{
			old: "agent.bats: lancement simple", goTest: "TestAgentLaunchEndWith",
			run: func(t *testing.T) frozenResult {
				_, got := frozenLaunch(t, "", nil)
				return got
			},
			want: frozenResult{code: 0, journal: frozenNormal,
				state: "droits-projet=\"\"\nrang=\"1\\n\"\nrang.lock=\"\"\n"},
		},
		{
			old: "agent-model.bats: --model", goTest: "TestAgentLaunchModelFlag",
			run: func(t *testing.T) frozenResult {
				_, got := frozenLaunch(t, "big-pickle", nil)
				return got
			},
			want: frozenResult{code: 0,
				journal: []string{
					"=== --model : big-pickle", "=== lock X", "=== lock X", "=== rank 1/9",
					"=== requested model chosen: big-pickle",
					"=== model opencode/big-pickle start 2023-11-14T22:13:20Z",
					"session big-pickle: instruction read, work starting",
					"the model big-pickle handled the instruction, the matching tests pass",
					"end of session big-pickle: no error, no permission refusal",
					"=== end with opencode/big-pickle (code 0)",
				},
				state: "droits-projet=\"\"\nrang.lock=\"\"\n"},
		},
		{
			old: "agent-model.bats: modele inconnu", goTest: "TestAgentLaunchUnknownModel",
			run: func(t *testing.T) frozenResult {
				_, got := frozenLaunch(t, "inconnu-free", nil)
				return got
			},
			want: frozenResult{code: 2,
				errOut: "devzone agent: unknown model: inconnu-free ; free models:\n" +
					"  big-pickle\n  deepseek-v4.1-flash-free\n  hy4-flash-free\n" +
					"  nemotron-3.5-super-vl-free\n  nemotron-3.5-lightning-free\n" +
					"  mimo-v2.6-flash-free\n  beam-free\n  flint-40b-free\n  longcat-2.5-free\n",
				state: "droits-projet=\"\"\n"},
		},
		{
			old: "agent.bats: state texte", goTest: "TestAgentStateText",
			run: func(t *testing.T) frozenResult {
				s, got := frozenLaunch(t, "", nil)
				os.Chtimes(s.journal(), fixed, fixed)
				got.out = AgentState(s.root, s.state, fixed, frozenPS, "")
				return got
			},
			want: frozenResult{code: 0, out: "devzone agent: state\n" + frozenStateLine,
				journal: frozenNormal, state: "droits-projet=\"\"\nrang=\"1\\n\"\nrang.lock=\"\"\n"},
		},
		{
			old: "agent-state-json.bats: running", goTest: "TestSessionRunning",
			run: func(t *testing.T) frozenResult {
				s, got := frozenLaunch(t, "", nil)
				os.Chtimes(s.journal(), fixed, fixed)
				got.out = AgentStateJSON(context.Background(), ExecRunner{}, s.root, s.state, frozenPS, fixed)
				return got
			},
			want: frozenResult{code: 0, out: frozenStateJSONLine,
				journal: frozenNormal, state: "droits-projet=\"\"\nrang=\"1\\n\"\nrang.lock=\"\"\n"},
		},
		{
			old: "agent.bats: usage", goTest: "TestRunHelpAndUsage",
			run: func(t *testing.T) frozenResult {
				s := newSandbox(t)
				var out, errOut strings.Builder
				o := s.opts()
				o.Out, o.Err = &out, &errOut
				return frozenResult{code: Run(context.Background(), o, nil), out: out.String(), errOut: errOut.String()}
			},
			want: frozenResult{code: 2, out: AgentHelp()},
		},
	}
	for _, c := range cases {
		t.Run(c.goTest, func(t *testing.T) {
			got := c.run(t)
			if got.code != c.want.code || got.out != c.want.out || got.errOut != c.want.errOut {
				t.Fatalf("%s (%s): code=%d out=%q err=%q ; want %d %q %q",
					c.goTest, c.old, got.code, got.out, got.errOut, c.want.code, c.want.out, c.want.errOut)
			}
			if strings.Join(got.journal, "\n") != strings.Join(c.want.journal, "\n") {
				t.Fatalf("%s journal:\n%q\nwant:\n%q", c.goTest, got.journal, c.want.journal)
			}
			if got.state != c.want.state {
				t.Fatalf("%s state:\n%q\nwant:\n%q", c.goTest, got.state, c.want.state)
			}
		})
	}
}
