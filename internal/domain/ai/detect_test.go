package ai

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const threeModels = `{"models":[
{"name":"qwen3-coder:32k","size":12345,"digest":"sha256:aaaa","details":{"type":"llm"}},
{"name":"nomic-embed-text:latest","size":67890,"details":{"type":"embedding"}},
{"name":"deepseek-coder:latest","size":99999,"digest":"sha256:bbbb","details":{"type":"llm"}}
]}`

// setMeasures writes a measurement file in the disposable home.
func setMeasures(t *testing.T, f fixture, data string) {
	t.Helper()
	path := f.o.measuresFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestModelsFiltersEmbedding checks that embedding models are ignored, both by
// declared type and by name.
func TestModelsFiltersEmbedding(t *testing.T) {
	f := newFixture(t)
	f.tags(threeModels)
	got := Models(ctx(), f.o)
	want := []string{"qwen3-coder:32k", "deepseek-coder:latest"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("models = %v, want %v", got, want)
	}
}

// TestFirstUsesForcedMeasurementAndRule checks the three choice rules in order.
func TestFirstUsesForcedMeasurementAndRule(t *testing.T) {
	f := newFixture(t)
	f.tags(threeModels)
	names := Models(ctx(), f.o)
	if got := First(ctx(), f.o, names); got != "qwen3-coder:32k" {
		t.Fatalf("rule = %q", got)
	}
	f.o.HostModel = "deepseek-coder:latest"
	if got := First(ctx(), f.o, names); got != "deepseek-coder:latest" {
		t.Fatalf("forced = %q", got)
	}
	f.o.HostModel = ""
	setMeasures(t, f, `{"deepseek-coder:latest":{"reussite":0.9,"tok_s":100},"inconnu":{"reussite":1,"tok_s":1}}`)
	if got := First(ctx(), f.o, names); got != "deepseek-coder:latest" {
		t.Fatalf("measurement = %q", got)
	}
}

// TestFirstBreaksTies checks success first, then speed then size and name.
func TestFirstBreaksTies(t *testing.T) {
	f := newFixture(t)
	setMeasures(t, f, `{"a:1":{"reussite":0.9,"tok_s":500},"b:1":{"reussite":0.9,"tok_s":100}}`)
	if got := measuredChoice(f.o, []string{"a:1", "b:1"}); got != "a:1" {
		t.Fatalf("speed tie = %q", got)
	}
	f.tags(`{"models":[{"name":"aaa-small:1","size":1,"details":{"type":"llm"}},{"name":"bbb-coder:1","size":9999,"details":{"type":"llm"}},{"name":"ccc-coder:1","size":5000,"details":{"type":"llm"}}]}`)
	if got := First(ctx(), f.o, Models(ctx(), f.o)); got != "ccc-coder:1" {
		t.Fatalf("size rule = %q", got)
	}
	f.tags(`{"models":[{"name":"zzz-coder:1","size":10,"details":{"type":"llm"}},{"name":"aaa-coder:1","size":10,"details":{"type":"llm"}}]}`)
	if got := First(ctx(), f.o, Models(ctx(), f.o)); got != "aaa-coder:1" {
		t.Fatalf("name rule = %q", got)
	}
}

// TestAbsenceWritesNothing checks that an unreachable service yields no models.
func TestAbsenceWritesNothing(t *testing.T) {
	f := newFixture(t)
	if got := Models(ctx(), f.o); len(got) != 0 {
		t.Fatalf("models = %v", got)
	}
	if got := First(ctx(), f.o, nil); got != "" {
		t.Fatalf("first = %q", got)
	}
}

// TestListModelsOutput checks the human readable listing of the command.
func TestListModelsOutput(t *testing.T) {
	f := newFixture(t)
	f.tags(threeModels)
	if code := Run(ctx(), f.o, nil); code != 0 {
		t.Fatalf("code = %d", code)
	}
	want := "devzone : models detected on the host (Ollama):\n  qwen3-coder:32k\n  deepseek-coder:latest\ndefault model: qwen3-coder:32k\n"
	if f.out.String() != want {
		t.Fatalf("out = %q, want %q", f.out.String(), want)
	}
}
