package podcmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/ai/guard"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestAIGuardProtocolFlag checks that the guard subcommand announces only an
// authorized call, and keeps its earlier output when the flag is absent.
func TestAIGuardProtocolFlag(t *testing.T) {
	command, ok := Registry.Lookup("ai")
	if !ok {
		t.Fatal("ai is not registered")
	}
	allowed := `{"tool":"bash","args":{"command":"kubectl get pods"},"cwd":"/tmp"}`
	forbidden := `{"tool":"bash","args":{"command":"` + "\x64\x6f\x63\x6b\x65\x72" + ` ps"},"cwd":"/tmp"}`
	refusal := guard.DefaultMessages().Refusal
	cases := []struct {
		name       string
		args       []string
		input      string
		code       int
		out        string
		errContain string
	}{
		{"announced allowed", []string{"guard", "--protocol", "1"}, allowed, 0, guard.AllowLine + "\n", ""},
		{"announced forbidden", []string{"guard", "--protocol", "1"}, forbidden, 2, "", refusal},
		{"unchanged allowed", []string{"guard"}, allowed, 0, "", ""},
		{"unchanged forbidden", []string{"guard"}, forbidden, 2, "", refusal},
		{"protocol 2", []string{"guard", "--protocol", "2"}, allowed, 2, "", "unsupported protocol"},
		{"protocol empty", []string{"guard", "--protocol", ""}, allowed, 2, "", "unsupported protocol"},
		{"protocol abc", []string{"guard", "--protocol", "abc"}, allowed, 2, "", "unsupported protocol"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			code := command.Run(&cli.Context{
				Args:  tc.args,
				Out:   &out,
				Err:   &errOut,
				Stdin: strings.NewReader(tc.input),
			})
			if code != tc.code || out.String() != tc.out {
				t.Fatalf("code %d, stdout %q; want %d and %q", code, out.String(), tc.code, tc.out)
			}
			if tc.errContain == "" && errOut.Len() != 0 {
				t.Fatalf("unexpected stderr %q", errOut.String())
			}
			if tc.errContain != "" && !strings.Contains(errOut.String(), tc.errContain) {
				t.Fatalf("stderr %q does not contain %q", errOut.String(), tc.errContain)
			}
			if code == 2 && strings.Contains(out.String(), guard.AllowLine) {
				t.Fatalf("refused call wrote the announcement: %q", out.String())
			}
		})
	}
}
