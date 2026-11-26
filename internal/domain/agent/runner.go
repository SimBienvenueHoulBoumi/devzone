package agent

import (
	"io"
	"os/exec"
	"sync"
	"time"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Runner runs external commands (opencode, git, gh, kubectl, curl, getent, ps,
// flock...); it is injectable for tests. It reuses the framework Runner.
type Runner = dzexec.Runner

// ExecRunner is the real Runner backed by os/exec.
type ExecRunner = dzexec.ExecRunner

// Opts carries optional inputs of a command run.
type Opts = dzexec.Opts

// Result holds captured output and exit status.
type Result = dzexec.Result

// Clock gives the current time and sleeps; injectable for tests (no real
// waiting). The shell reads `date +%s` and `sleep`.
type Clock interface {
	Now() time.Time
	Sleep(d time.Duration)
}

// RealClock is the system clock.
type RealClock struct{}

// Now returns the current time.
func (RealClock) Now() time.Time { return time.Now() }

// Sleep pauses for d.
func (RealClock) Sleep(d time.Duration) { time.Sleep(d) }

// SessionCmd is one opencode run: binary, args, dir, env, stdin, output sink.
type SessionCmd struct {
	Name   string
	Args   []string
	Dir    string
	Env    []string
	Unset  []string
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// SessionProcess is a started opencode process (pid, kill, wait).
type SessionProcess interface {
	Pid() int
	Alive() bool
	Kill() error
	Wait() int
}

// SessionStarter starts opencode run in the background; injectable for tests.
// The real one uses os/exec; a fake can script a process. opencode goes
// through a starter because a session is monitored while it runs and killed.
type SessionStarter interface {
	Start(cmd SessionCmd) (SessionProcess, error)
}

// ExecSessionStarter starts real processes with os/exec.
type ExecSessionStarter struct{}

// Start launches the command in its own process group so kill can stop
// children too (the shell used pkill -P then kill).
func (ExecSessionStarter) Start(cmd SessionCmd) (SessionProcess, error) {
	c := exec.Command(cmd.Name, cmd.Args...)
	c.Dir = cmd.Dir
	c.Stdin = cmd.Stdin
	c.Stdout = cmd.Stdout
	c.Stderr = cmd.Stderr
	c.Env = childEnv(cmd.Env, cmd.Unset)
	setProcGroup(c)
	if err := c.Start(); err != nil {
		return nil, err
	}
	return &execProcess{cmd: c}, nil
}

// execProcess adapts os/exec.Cmd.
type execProcess struct {
	cmd  *exec.Cmd
	done chan struct{}
	code int
	once sync.Once
}

func (p *execProcess) Pid() int { return p.cmd.Process.Pid }

// start registers a single cmd.Wait goroutine.
func (p *execProcess) start() {
	p.once.Do(func() {
		p.done = make(chan struct{})
		go func() {
			err := p.cmd.Wait()
			code := 0
			if err != nil {
				code = 127
				if ee, ok := err.(*exec.ExitError); ok {
					code = ee.ExitCode()
				}
			}
			p.code = code
			close(p.done)
		}()
	})
}

// Alive reports whether the process is still running (kill -0).
func (p *execProcess) Alive() bool {
	p.start()
	select {
	case <-p.done:
		return false
	default:
		return processAlive(p.cmd.Process)
	}
}

// Kill stops children then the process (shell pkill -P; kill), then waits.
func (p *execProcess) Kill() error {
	p.start()
	killGroup(p.cmd.Process)
	<-p.done
	return nil
}

// Wait returns the exit code (127 when it could not be started).
func (p *execProcess) Wait() int {
	p.start()
	<-p.done
	return p.code
}
