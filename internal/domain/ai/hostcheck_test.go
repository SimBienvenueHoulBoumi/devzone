package ai

import (
	"strings"
	"testing"
)

// tagsWith builds a payload with one model using the given digest.
func tagsWith(name, digest string) string {
	return `{"models":[{"name":"` + name + `","size":12345,"digest":"` + digest + `","details":{"type":"llm"}}]}`
}

// TestCheckUpToDateAndUpdate checks the digest comparison and the pull advice.
func TestCheckUpToDateAndUpdate(t *testing.T) {
	f := newFixture(t)
	sum := f.manifest("qwen3-coder:32k", `{"schemaVersion":2}`, 0)
	f.tags(tagsWith("qwen3-coder:32k", "sha256:"+sum))
	Check(ctx(), f.o)
	if !strings.Contains(f.out.String(), "qwen3-coder:32k : up to date") {
		t.Fatalf("out = %q", f.out.String())
	}
	if strings.Contains(f.out.String(), "update available") {
		t.Fatalf("out = %q", f.out.String())
	}

	g := newFixture(t)
	g.manifest("qwen3-coder:32k", `{"schemaVersion":2}`, 0)
	g.tags(tagsWith("qwen3-coder:32k", "sha256:deadbeef"))
	Check(ctx(), g.o)
	if !strings.Contains(g.out.String(), "qwen3-coder:32k : update available") ||
		!strings.Contains(g.out.String(), "on the host: ollama pull qwen3-coder:32k") {
		t.Fatalf("out = %q", g.out.String())
	}
}

// TestCheckNotVerifiable checks names with a slash, 404 and unreachable registry.
func TestCheckNotVerifiable(t *testing.T) {
	f := newFixture(t)
	f.tags(`{"models":[
{"name":"hf.co/org/Nemotron:Q4_0","size":1,"digest":"sha256:aaaa","details":{"type":"llm"}},
{"name":"absent:latest","size":1,"digest":"sha256:aaaa","details":{"type":"llm"}}]}`)
	f.manifest("absent:latest", "", 1)
	Check(ctx(), f.o)
	if !strings.Contains(f.out.String(), "hf.co/org/Nemotron:Q4_0 : not verifiable") ||
		!strings.Contains(f.out.String(), "absent:latest : not verifiable") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestCheckOneRequestPerModel checks that no download or pull is performed.
func TestCheckOneRequestPerModel(t *testing.T) {
	f := newFixture(t)
	sum := f.manifest("a-coder:1", `{}`, 0)
	f.manifest("b-coder:1", `{}`, 0)
	f.tags(tagsWith("a-coder:1", "sha256:"+sum))
	Check(ctx(), f.o)
	gets := 0
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "/v2/library/") {
			gets++
		}
		if call.Name != "curl" {
			t.Fatalf("unexpected command %s", call.Name)
		}
	}
	if gets != 1 {
		t.Fatalf("manifest requests = %d, want 1", gets)
	}
}

// TestCheckAbsence prints the clean message when the service does not answer.
func TestCheckAbsence(t *testing.T) {
	f := newFixture(t)
	Check(ctx(), f.o)
	want := "devzone: no Ollama model detected on " + f.o.url() + " (answer on /api/tags)\n"
	if f.out.String() != want {
		t.Fatalf("out = %q, want %q", f.out.String(), want)
	}
}

// TestReportShowsReasonAndMeasurement checks the report lines and the reason.
func TestReportShowsReasonAndMeasurement(t *testing.T) {
	f := newFixture(t)
	sum := f.manifest("qwen3-coder:32k", `{}`, 0)
	f.tags(tagsWith("qwen3-coder:32k", "sha256:"+sum))
	setMeasures(t, f, `{"qwen3-coder:32k":{"reussite":0.8,"tok_s":500}}`)
	Report(ctx(), f.o)
	out := f.out.String()
	for _, want := range []string{
		"host (Ollama) models detected:",
		"qwen3-coder:32k : up to date ; size 12345",
		"measurement reussite 0.8, tok_s 500",
		"chosen model: qwen3-coder:32k (measurement)",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("out = %q, want %q", out, want)
		}
	}
	f.o.HostModel = "autre:1"
	f.out.Reset()
	Report(ctx(), f.o)
	if !strings.Contains(f.out.String(), "chosen model: autre:1 (DEVZONE_HOST_MODEL)") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestRunnerCallsAreFake checks that the injected runner is the only command path.
func TestRunnerCallsAreFake(t *testing.T) {
	f := newFixture(t)
	f.tags(`{"models":[]}`)
	Run(ctx(), f.o, []string{"check"})
	if len(f.r.Calls()) == 0 {
		t.Fatal("no runner call recorded")
	}
}
