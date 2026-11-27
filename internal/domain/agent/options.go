package agent

import (
	"fmt"
	"io"
	"os/exec"
)

// ResumeSuffix appended to brief when resuming a previous session.
const ResumeSuffix = "\n\nRESUME: a previous session was interrupted. Read git status, git diff and git log in the folder, check this work against the brief above, fix what deviates from it and finish what is missing.\n"

// NetworkRetries retries of same session for a network cause, per model.
const NetworkRetries = 3

// Options carries dependencies for `devzone agent`.
type Options struct {
	Runner   Runner
	Clock    Clock
	Starter  SessionStarter
	LookPath func(string) (string, error)
	Out      io.Writer
	Err      io.Writer
	// DevcontainerDir is $ICI (.devcontainer); agent.json + devzone + agent-rights.
	DevcontainerDir string
	// Racine is $RACINE (DEVZONE_ROOT or parent of DevcontainerDir).
	Racine string
	// StateDir is $AGENT_STATE (DEVZONE_AGENT_STATE or ~/.local/state/oc-lancer).
	StateDir string
	// Home is $HOME.
	Home string
	// ModelList is --model comma list ("" when absent).
	ModelList string
	// LocalMode forces local (--local).
	LocalMode bool
}

func (o Options) clock() Clock {
	if o.Clock == nil {
		return RealClock{}
	}
	return o.Clock
}

func (o Options) runner() Runner {
	if o.Runner == nil {
		return ExecRunner{}
	}
	return o.Runner
}

func (o Options) starter() SessionStarter {
	if o.Starter == nil {
		return ExecSessionStarter{}
	}
	return o.Starter
}

// lookPath returns the program lookup of this run. Tests inject it so they
// never have to put a fake binary in PATH.
func (o Options) lookPath() func(string) (string, error) {
	if o.LookPath == nil {
		return exec.LookPath
	}
	return o.LookPath
}

func (o Options) err() io.Writer {
	if o.Err == nil {
		return io.Discard
	}
	return o.Err
}

func (o Options) out() io.Writer {
	if o.Out == nil {
		return io.Discard
	}
	return o.Out
}

// refuse prints `devzone agent: msg` to stderr; caller returns code 2.
func refuse(w io.Writer, msg string) int {
	fmt.Fprintln(w, "devzone agent: "+msg)
	return 2
}
