package guard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// Messages holds the two refusal texts of the guard, kept identical to the
// message files used by the installed hook.
type Messages struct {
	Refusal     string
	KubeRefusal string
}

// DefaultMessages returns the frozen messages of the guard.
func DefaultMessages() Messages {
	return Messages{Refusal: refusal, KubeRefusal: kubeRefusal}
}

// Run checks one tool call read from in. It writes a refusal to errOut and
// returns 2 when a command is blocked, 0 otherwise. The administrator context
// refusal comes first; the host override only concerns the other commands.
func Run(in io.Reader, format string, allowHost bool, errOut io.Writer, messages Messages) int {
	data, err := io.ReadAll(in)
	if err != nil || len(bytes.TrimSpace(data)) == 0 {
		return 0
	}
	cmd, ok := commandOf(data, format)
	if !ok {
		return 0
	}
	if KubeForbidden(cmd) {
		fmt.Fprintln(errOut, messages.KubeRefusal)
		return 2
	}
	if allowHost {
		return 0
	}
	if CommandForbidden(cmd) {
		fmt.Fprintln(errOut, messages.Refusal)
		return 2
	}
	return 0
}

// commandOf extracts the shell command of a tool call, only for shell tools.
func commandOf(data []byte, format string) (string, bool) {
	var doc struct {
		Tool      string          `json:"tool"`
		ToolName  string          `json:"tool_name"`
		Args      json.RawMessage `json:"args"`
		ToolInput json.RawMessage `json:"tool_input"`
	}
	if json.Unmarshal(data, &doc) != nil {
		return "", false
	}
	tool, inner := doc.Tool, doc.Args
	if format == "claude" {
		tool, inner = doc.ToolName, doc.ToolInput
	}
	if tool != "bash" && tool != "shell" && tool != "Bash" {
		return "", false
	}
	if len(inner) == 0 || inner[0] != '{' {
		return "", false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(inner, &fields) != nil {
		return "", false
	}
	raw, ok := fields["command"]
	if !ok {
		return "", false
	}
	var cmd string
	if json.Unmarshal(raw, &cmd) != nil {
		return "", false
	}
	return cmd, cmd != ""
}
