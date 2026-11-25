// Package fake provides a programmable Runner for tests.
package fake

import (
	"context"
	"fmt"
	"sync"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Response is a programmed answer for a command.
type Response struct {
	Stdout []byte
	Stderr []byte
	Code   int
	Err    error
}

// Call records one invocation of the runner.
type Call struct {
	Name string
	Args []string
	Opts exec.Opts
}

// Runner is a fake exec.Runner whose answers are programmed by name and args.
type Runner struct {
	mu        sync.Mutex
	responses map[string]Response
	calls     []Call
}

// New creates an empty fake runner.
func New() *Runner {
	return &Runner{responses: map[string]Response{}}
}

// key builds the lookup key for a command.
func key(name string, args []string) string {
	return name + "\x00" + joinArgs(args)
}

func joinArgs(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += "\x00"
		}
		out += a
	}
	return out
}

// Run implements exec.Runner.
func (r *Runner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, Call{Name: name, Args: append([]string(nil), args...), Opts: opts})
	resp, ok := r.responses[key(name, args)]
	if !ok {
		resp, ok = r.responses[name+"\x00"]
	}
	if !ok {
		return exec.Result{}, fmt.Errorf("fake runner: no response programmed for %s %v", name, args)
	}
	return exec.Result{Stdout: resp.Stdout, Stderr: resp.Stderr, Code: resp.Code}, resp.Err
}

// Calls returns a copy of the recorded calls.
func (r *Runner) Calls() []Call {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Call, len(r.calls))
	copy(out, r.calls)
	return out
}

// --- registration helpers (several names for the same operation) ---

func (r *Runner) register(name string, args []string, resp Response) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.responses[key(name, args)] = resp
}

func (r *Runner) On(name string, args []string, resp exec.Result) {
	r.register(name, args, Response{Stdout: resp.Stdout, Stderr: resp.Stderr, Code: resp.Code})
}

func (r *Runner) OnError(name string, args []string, resp exec.Result, err error) {
	r.register(name, args, Response{Stdout: resp.Stdout, Stderr: resp.Stderr, Code: resp.Code, Err: err})
}

func (r *Runner) Set(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) SetResponse(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) SetErr(name string, args []string, resp exec.Result, err error) {
	r.OnError(name, args, resp, err)
}

func (r *Runner) Add(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) AddResponse(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) Respond(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) Program(name string, args []string, resp exec.Result) { r.On(name, args, resp) }

func (r *Runner) When(name string, args []string) *ResponseSetter {
	return &ResponseSetter{r: r, name: name, args: args}
}

// ResponseSetter allows a fluent registration.
type ResponseSetter struct {
	r    *Runner
	name string
	args []string
}

func (s *ResponseSetter) Return(resp exec.Result) { s.r.On(s.name, s.args, resp) }
func (s *ResponseSetter) ReturnErr(resp exec.Result, err error) {
	s.r.OnError(s.name, s.args, resp, err)
}

// Allow programming a full Response (with Err) directly.
func (r *Runner) OnResponse(name string, args []string, resp Response) {
	r.register(name, args, resp)
}
