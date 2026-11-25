// Package cli provides the shared command registry used by both binaries.
package cli

import (
	"io"
	"sort"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Context carries the data of a command run.
type Context struct {
	Args   []string
	Out    io.Writer
	Err    io.Writer
	Stdin  io.Reader
	Runner exec.Runner
}

// Handler runs a command and returns its exit status.
type Handler func(ctx *Context) int

// Command describes a registered command.
type Command struct {
	Name     string
	Aliases  []string
	Bare     bool
	Run      Handler
	Delegate Handler
}

// Registry holds the commands of one binary.
type Registry struct {
	commands map[string]Command
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{commands: map[string]Command{}}
}

// Register adds a command and its aliases.
func (r *Registry) Register(c Command) {
	r.commands[c.Name] = c
	for _, a := range c.Aliases {
		r.commands[a] = c
	}
}

// Lookup returns the command registered under name (or an alias).
func (r *Registry) Lookup(name string) (Command, bool) {
	c, ok := r.commands[name]
	return c, ok
}

// Names returns the registered names and aliases, sorted.
func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.commands))
	for name := range r.commands {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Run executes args when their first word is registered. It returns false when
// no command matches, so the caller can delegate to the shell.
func (r *Registry) Run(args []string, ctx *Context) (int, bool) {
	if len(args) == 0 {
		return 0, false
	}
	cmd, ok := r.Lookup(args[0])
	if !ok {
		return 0, false
	}
	if ctx == nil {
		ctx = &Context{}
	}
	ctx.Args = args[1:]
	if cmd.Bare && len(ctx.Args) > 0 {
		if cmd.Delegate != nil {
			return cmd.Delegate(ctx), true
		}
		return 0, false
	}
	if cmd.Run != nil {
		return cmd.Run(ctx), true
	}
	if cmd.Delegate != nil {
		return cmd.Delegate(ctx), true
	}
	return 0, false
}
