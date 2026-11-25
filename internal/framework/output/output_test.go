package output

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestOutputPrefixes(t *testing.T) {
	var buf bytes.Buffer
	OK(&buf, "done")
	Warn(&buf, "careful")
	Fail(&buf, "boom")
	Info(&buf, "note")
	want := "✔ done\n⚠ careful\n✖ boom\nℹ note\n"
	if buf.String() != want {
		t.Fatalf("got %q want %q", buf.String(), want)
	}
}

func TestOutputJSON(t *testing.T) {
	var buf bytes.Buffer
	if err := JSON(&buf, map[string]int{"a": 1}); err != nil {
		t.Fatal(err)
	}
	var v map[string]int
	if err := json.Unmarshal(buf.Bytes(), &v); err != nil {
		t.Fatal(err)
	}
	if string(buf.Bytes()) != "{\n  \"a\": 1\n}\n" {
		t.Fatalf("got %q", buf.String())
	}
}
