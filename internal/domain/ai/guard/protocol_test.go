package guard

import (
	"bytes"
	"strings"
	"testing"
)

// TestProtocolOneAnnouncesAllowedCall checks the exact stdout line and status
// of an authorized call in protocol mode, in both call formats.
func TestProtocolOneAnnouncesAllowedCall(t *testing.T) {
	messages := DefaultMessages()
	for _, format := range []string{"opencode", "claude"} {
		t.Run(format, func(t *testing.T) {
			var out, errOut bytes.Buffer
			code := RunProtocol(strings.NewReader(callInput(t, format, "kubectl get pods")),
				format, ProtocolOne, false, &out, &errOut, messages)
			if code != 0 || out.String() != AllowLine+"\n" || errOut.Len() != 0 {
				t.Fatalf("code %d, stdout %q, stderr %q; want 0, %q and no stderr",
					code, out.String(), errOut.String(), AllowLine+"\n")
			}
		})
	}
}

// TestProtocolOneNeverAnnouncesRefusal checks that both refusal kinds keep
// their frozen stderr text and produce no announcement on stdout.
func TestProtocolOneNeverAnnouncesRefusal(t *testing.T) {
	messages := DefaultMessages()
	forbidden := "\x64\x6f\x63\x6b\x65\x72" + " ps"
	cases := []struct {
		name string
		cmd  string
		want string
	}{
		{"command", forbidden, messages.Refusal},
		{"administrator", "cat ~/.kube/hote.config", messages.KubeRefusal},
	}
	for _, format := range []string{"opencode", "claude"} {
		for _, tc := range cases {
			t.Run(format+"/"+tc.name, func(t *testing.T) {
				var out, errOut bytes.Buffer
				code := RunProtocol(strings.NewReader(callInput(t, format, tc.cmd)),
					format, ProtocolOne, false, &out, &errOut, messages)
				if code != 2 || out.Len() != 0 || errOut.String() != tc.want+"\n" {
					t.Fatalf("code %d, stdout %q, stderr %q; want 2, no stdout and %q",
						code, out.String(), errOut.String(), tc.want+"\n")
				}
			})
		}
	}
}

// TestUnknownProtocolsAreRefused checks that every unsupported value is
// rejected before stdout can receive an authorization line.
func TestUnknownProtocolsAreRefused(t *testing.T) {
	messages := DefaultMessages()
	for _, protocol := range []string{"2", "", "abc"} {
		t.Run("protocol="+protocol, func(t *testing.T) {
			var out, errOut bytes.Buffer
			code := RunProtocol(strings.NewReader(callInput(t, "opencode", "kubectl get pods")),
				"opencode", protocol, false, &out, &errOut, messages)
			if code != 2 || out.Len() != 0 {
				t.Fatalf("code %d, stdout %q; want 2 and no stdout", code, out.String())
			}
			if !strings.Contains(errOut.String(), "unsupported protocol") ||
				strings.Contains(errOut.String(), AllowLine) {
				t.Fatalf("stderr %q is not a clear protocol refusal", errOut.String())
			}
		})
	}
}

// TestWithoutProtocolKeepsFrozenOutput checks four calls in both formats
// against the byte-for-byte output of the guard before protocol mode existed.
func TestWithoutProtocolKeepsFrozenOutput(t *testing.T) {
	messages := DefaultMessages()
	forbidden := "\x64\x6f\x63\x6b\x65\x72" + " ps"
	cases := []struct {
		name string
		cmd  string
		code int
		err  string
	}{
		{"allowed", "kubectl get pods", 0, ""},
		{"other allowed", "echo hello", 0, ""},
		{"forbidden", forbidden, 2, messages.Refusal},
		{"administrator", "cat ~/.kube/hote.config", 2, messages.KubeRefusal},
	}
	for _, format := range []string{"opencode", "claude"} {
		for _, tc := range cases {
			t.Run(format+"/"+tc.name, func(t *testing.T) {
				var errOut bytes.Buffer
				code := Run(strings.NewReader(callInput(t, format, tc.cmd)), format, false, &errOut, messages)
				wantErr := ""
				if tc.err != "" {
					wantErr = tc.err + "\n"
				}
				if code != tc.code || errOut.String() != wantErr {
					t.Fatalf("code %d, stderr %q; want %d and %q", code, errOut.String(), tc.code, wantErr)
				}
			})
		}
	}
}
