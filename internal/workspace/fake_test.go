package workspace

import (
	"errors"
	"io"
	"strings"
)

// reply is the answer of the fake kubectl to the calls whose joined arguments
// contain match
type reply struct {
	match  string
	stdout string
	stderr string
	status int
	err    error
}

// fakeRunner answers kubectl calls from its replies: the first rule that matches
// wins. The calls and the standard input piped to them are recorded. A call
// without reply returns an error, which the tests then see as a failure.
type fakeRunner struct {
	replies []reply
	calls   []string
	stdins  []string
}

// Kubectl records the call and writes the reply of the first matching rule
func (f *fakeRunner) Kubectl(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	line := strings.Join(args, " ")
	f.calls = append(f.calls, line)
	input := ""
	if stdin != nil {
		data, _ := io.ReadAll(stdin)
		input = string(data)
	}
	f.stdins = append(f.stdins, input)
	for _, r := range f.replies {
		if strings.Contains(line, r.match) {
			_, _ = io.WriteString(stdout, r.stdout)
			_, _ = io.WriteString(stderr, r.stderr)
			return r.status, r.err
		}
	}
	return 0, errors.New("no reply for kubectl " + line)
}
