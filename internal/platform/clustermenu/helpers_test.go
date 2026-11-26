package clustermenu

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// errNotFound is what the look-up of a missing tool returns
var errNotFound = errors.New("executable file not found in $PATH")

// fixture is a menu wired to a fake runner, answers typed on stdin and output buffers
type fixture struct {
	runner *fake.Runner
	menu   *Menu
	out    *bytes.Buffer
	errOut *bytes.Buffer
	found  bool
}

// newFixture builds a menu whose answers are answers (one per line). The
// minikube look-up finds the tool only when found is true; GOOS is linux.
func newFixture(answers string, found bool) *fixture {
	f := &fixture{runner: fake.New(), out: &bytes.Buffer{}, errOut: &bytes.Buffer{}, found: found}
	f.menu = &Menu{
		Ctx:    context.Background(),
		Runner: f.runner,
		LookPath: func(file string) (string, error) {
			if file == "minikube" && f.found {
				return "/usr/local/bin/minikube", nil
			}
			return "", errNotFound
		},
		GOOS: "linux",
		In:   bufio.NewReader(strings.NewReader(answers)),
		Out:  f.out,
		Err:  f.errOut,
	}
	return f
}

// contexts programs kubectl config get-contexts -o name with the given names
func (f *fixture) contexts(names ...string) {
	f.runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte(strings.Join(names, "\n") + "\n")})
}

// server programs the API server address of a context
func (f *fixture) server(ctx, addr string) {
	f.runner.On("kubectl", []string{"config", "view", "--minify", "--context", ctx, "-o", "jsonpath={.clusters[0].cluster.server}"}, exec.Result{Stdout: []byte(addr)})
}

// calledWith tells whether a command with these arguments was run
func (f *fixture) calledWith(name string, args ...string) bool {
	for _, c := range f.runner.Calls() {
		if c.Name == name && strings.Join(c.Args, " ") == strings.Join(args, " ") {
			return true
		}
	}
	return false
}
