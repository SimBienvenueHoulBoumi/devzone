package guard

import (
	"fmt"
	"io"
)

// ProtocolOne is the only announced protocol version the guard accepts.
const ProtocolOne = "1"

// AllowLine is the exact success line written in protocol mode. Callers and
// tests share this single definition so the announcement cannot drift.
const AllowLine = "devzone-guard/1 allow"

// RunProtocol checks one tool call and announces the result in protocol mode.
// An unknown protocol is refused before the call is inspected, and the allow
// line is written only after a normal run has authorized the call.
func RunProtocol(in io.Reader, format, protocol string, allowHost bool, out, errOut io.Writer, messages Messages) int {
	if protocol != ProtocolOne {
		fmt.Fprintf(errOut, "devzone guard: unsupported protocol %q; update devzone\n", protocol)
		return 2
	}
	code := Run(in, format, allowHost, errOut, messages)
	if code != 0 {
		return code
	}
	fmt.Fprintln(out, AllowLine)
	return 0
}
