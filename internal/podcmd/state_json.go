package podcmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// jsonMember holds one key and its encoded value of a JSON object.
type jsonMember struct {
	key   string
	value any
}

// jsonObject keeps the insertion order of the shell jq contract when encoded.
type jsonObject []jsonMember

// MarshalJSON writes the members in insertion order, like a jq object literal.
func (o jsonObject) MarshalJSON() ([]byte, error) {
	buf := bytes.NewBufferString("{")
	for i, member := range o {
		if i > 0 {
			buf.WriteByte(',')
		}
		key, err := jsonValue(member.key)
		if err != nil {
			return nil, err
		}
		buf.Write(key)
		buf.WriteByte(':')
		value, err := jsonValue(member.value)
		if err != nil {
			return nil, err
		}
		buf.Write(value)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// set replaces a value in place, or appends the key when it is new, as jq does.
func (o *jsonObject) set(key string, value any) {
	for i := range *o {
		if (*o)[i].key == key {
			(*o)[i].value = value
			return
		}
	}
	*o = append(*o, jsonMember{key: key, value: value})
}

// rawJSON is a validated JSON document inserted verbatim to keep its key order.
type rawJSON []byte

// MarshalJSON returns the raw document after validation.
func (r rawJSON) MarshalJSON() ([]byte, error) {
	if !json.Valid(r) {
		return nil, fmt.Errorf("invalid raw JSON: %s", r)
	}
	return r, nil
}

// jsonValue encodes without HTML escaping, like jq, and without the encoder newline.
func jsonValue(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// jsonDeps carries the roots and runner used by the JSON status sections.
type jsonDeps struct {
	ctx  *cli.Context
	st   *state.State
	root string
	code string
}

// run executes a command and returns its stdout, exit status and start error.
func (d jsonDeps) run(name string, args ...string) (string, int, error) {
	return d.runEnv(nil, name, args...)
}

// runEnv executes a command with extra environment assignments.
func (d jsonDeps) runEnv(env []string, name string, args ...string) (string, int, error) {
	res, err := d.ctx.Runner.Run(context.Background(), name, args, exec.Opts{Env: env})
	return string(res.Stdout), res.Code, err
}

// runBoth returns stdout and stderr as one string, as a shell 2>&1 capture does.
func (d jsonDeps) runBoth(name string, args ...string) (string, int, error) {
	res, err := d.ctx.Runner.Run(context.Background(), name, args, exec.Opts{})
	return string(res.Stdout) + string(res.Stderr), res.Code, err
}

// trimNewlines removes the trailing newlines stripped by shell command substitution.
func trimNewlines(v string) string {
	for len(v) > 0 && (v[len(v)-1] == '\n' || v[len(v)-1] == '\r') {
		v = v[:len(v)-1]
	}
	return v
}

// strOrNil returns nil for an empty string so JSON carries a null like the shell.
func strOrNil(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// writeJSON emits the compact-free indented object followed by a newline.
func writeJSON(out io.Writer, value any) error {
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}
