package agent

import (
	"strings"
	"testing"
)

func TestErrorCause(t *testing.T) {
	cases := map[string]string{
		"not available in your country": "pays",
		"Free usage limit":              "quota",
		"content filter":                "filtre",
		"ECONNREFUSED":                  "reseau",
		"ENOTFOUND":                     "reseau",
		"ETIMEDOUT":                     "reseau",
		"Model is unavailable":          "autre",
		"Upstream request failed":       "autre",
		"network down":                  "reseau",
		"EAI_AGAIN":                     "reseau",
		"ECONNRESET":                    "reseau",
		"fetch failed":                  "reseau",
	}
	for in, want := range cases {
		if got := ErrorCause(in); got != want {
			t.Errorf("ErrorCause(%q)=%q want %q", in, got, want)
		}
	}
}

func TestCauseLabel(t *testing.T) {
	for c, want := range map[string]string{
		"pays": "country", "quota": "quota", "filtre": "filter", "reseau": "network",
		"mute": "silent", "muet": "silent", "autre": "other", "x": "other",
	} {
		if got := CauseLabel(c); got != want {
			t.Errorf("CauseLabel(%q)=%q", c, got)
		}
	}
}

func TestExclusionDuration(t *testing.T) {
	if ExclusionDuration("pays") != 604800 {
		t.Fatal("pays != 7d")
	}
	if ExclusionDuration("quota") != 3600 {
		t.Fatal("quota != 1h")
	}
	t.Setenv("DEVZONE_AGENT_COUNTRY_EXCLUSION", "60")
	if ExclusionDuration("pays") != 60 {
		t.Fatal("country env not read")
	}
}

func TestExclusionLabel(t *testing.T) {
	if ExclusionLabel("pays") != "7 d" {
		t.Fatal("7 d", ExclusionLabel("pays"))
	}
	if ExclusionLabel("quota") != "1 h" {
		t.Fatal("1 h")
	}
}

func TestErrorLines(t *testing.T) {
	log := "timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title Free usage limit reached\n" +
		"timestamp=2024-01-01T00:01:00Z level=ERROR small=false agent=build Upstream request failed\n" +
		"some other text\n" +
		"\x1b[31mtimestamp=2024-01-01T00:02:00Z level=ERROR agent=x network\x1b[0m\n"
	got := ErrorLines(log)
	if got == "" {
		t.Fatal("empty")
	}
	if strings.Contains(got, "agent=title") {
		t.Fatal("agent=title kept")
	}
	if !strings.Contains(got, "agent=build") {
		t.Fatal("agent=build dropped")
	}
	if !strings.Contains(got, "network") {
		t.Fatal("ansi not stripped")
	}
	if strings.Contains(got, "some other text") {
		t.Fatal("non-error kept")
	}
}

func TestErrorCauseTitleOnly(t *testing.T) {
	// title-only quota ignored -> autre
	log := "timestamp=2024-01-01T00:00:00Z level=ERROR small=true agent=title Free usage limit reached"
	if ErrorCause(ErrorLines(log)) != CauseOther {
		t.Fatal("title-only should be autre")
	}
}
