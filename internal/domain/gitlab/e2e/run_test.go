package e2e

import (
	"strings"
	"testing"
)

// TestParseArgs checks the two options and the refusal of an unknown one.
func TestParseArgs(t *testing.T) {
	for _, tc := range []struct {
		args                []string
		full, publish, help bool
		wantErr             string
	}{
		{args: nil},
		{args: []string{"--complet", "--statut"}, full: true, publish: true},
		{args: []string{"--help"}, help: true},
		{args: []string{"-h"}, help: true},
		{args: []string{"--nope"}, wantErr: "devzone test-gitlab : unknown option: --nope"},
	} {
		full, publish, help, err := parseArgs(tc.args)
		if tc.wantErr != "" {
			if err == nil || err.Error() != tc.wantErr {
				t.Errorf("args %v: err = %v, want %q", tc.args, err, tc.wantErr)
			}
			continue
		}
		if err != nil || full != tc.full || publish != tc.publish || help != tc.help {
			t.Errorf("args %v: %v %v %v %v", tc.args, full, publish, help, err)
		}
	}
}

// TestE2EAllGreen checks the seven steps, the summary, the exit code, the key
// removal and that the token is never shown.
func TestE2EAllGreen(t *testing.T) {
	f := newFixture(t)
	if code := f.run(); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.err.String())
	}
	out := f.out.String()
	for _, want := range []string{
		"✔ 1. module", "✔ 2. state", "✔ 3. host name", "✔ 4. pipeline",
		"✔ 5. HTTP and SSH clones", "✔ 6. platform", "✔ 7. repowarden integration",
		"devzone test-gitlab : summary", "total: 7 step(s)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "token-root-secret") || strings.Contains(f.err.String(), "token-root-secret") {
		t.Error("token shown")
	}
	if !strings.Contains(strings.Join(f.apiCalls, "\n"), "DELETE /api/v4/user/keys/7") {
		t.Errorf("key not removed: %v", f.apiCalls)
	}
	if !f.hasCall("platform github") {
		t.Errorf("platform not restored: %v", f.calls())
	}
}

// TestE2EModuleEnableFails checks the reason and the code when the module
// cannot be enabled.
func TestE2EModuleEnableFails(t *testing.T) {
	f := newFixture(t)
	f.r.On(scriptName(), []string{"is-enabled", "gitlab"}, execResultCode(1))
	f.r.On(scriptName(), []string{"enable", "gitlab"}, execResultCode(1))
	if code := f.run(); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	for _, want := range []string{"✖ 1. module", "devzone enable gitlab failed"} {
		if !strings.Contains(f.out.String(), want) {
			t.Errorf("output lacks %q: %s", want, f.out.String())
		}
	}
}

// TestE2EStateFailures checks the two reasons of step 2: unreadable state and
// runner offline.
func TestE2EStateFailures(t *testing.T) {
	for _, tc := range []struct {
		name, state, want string
	}{
		{"unreadable", "", "state: unreadable"},
		{"offline", "ready: http://gitlab.localhost:8929, runner offline", "runner offline"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.r.On(scriptName(), []string{"gitlab", "status"}, execResultOut(tc.state))
			if code := f.run(); code == 0 {
				t.Fatal("code = 0, want failure")
			}
			for _, want := range []string{"✖ 2. state", tc.want} {
				if !strings.Contains(f.out.String(), want) {
					t.Errorf("output lacks %q: %s", want, f.out.String())
				}
			}
		})
	}
}

// TestE2EPipelineFailures checks step 4: creation failure, final failure and
// timeout exceeded (with the injected clock, never a real wait).
func TestE2EPipelineFailures(t *testing.T) {
	for _, tc := range []struct {
		name, body, want string
	}{
		{"create", "fail", "creation of the pipeline"},
		{"failed", "failed", "pipeline failed"},
		{"timeout", "running", "timeout 2 s exceeded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.pipeBody = tc.body
			if code := f.run(); code == 0 {
				t.Fatal("code = 0, want failure")
			}
			for _, want := range []string{"✖ 4. pipeline", tc.want} {
				if !strings.Contains(f.out.String(), want) {
					t.Errorf("output lacks %q: %s", want, f.out.String())
				}
			}
		})
	}
}

// TestE2EPipelineURL checks that a failed pipeline cites its web URL.
func TestE2EPipelineURL(t *testing.T) {
	f := newFixture(t)
	f.pipeBody = "failed"
	if code := f.run(); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.out.String(), "/devzone/demo/-/pipelines/42") {
		t.Errorf("output = %q", f.out.String())
	}
}

// TestE2EPipelineRunningThenSuccess checks the poll that succeeds on the
// second answer, as the fake of the shell test did.
func TestE2EPipelineRunningThenSuccess(t *testing.T) {
	f := newFixture(t)
	if code := f.run(); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(f.out.String(), "✔ 4. pipeline") {
		t.Errorf("output = %q", f.out.String())
	}
}

// TestE2EUsageAndOptions checks help, code 0, and the refusal of an unknown
// option with the usage on the standard error.
func TestE2EUsageAndOptions(t *testing.T) {
	f := newFixture(t)
	if code := f.run("--help"); code != 0 {
		t.Fatalf("help code = %d", code)
	}
	if !strings.Contains(f.out.String(), "devzone test-gitlab [--complet] [--statut]") {
		t.Errorf("help output = %q", f.out.String())
	}
	if code := f.run("--nope"); code != 2 {
		t.Fatalf("unknown option code = %d, want 2", code)
	}
	if !strings.Contains(f.err.String(), "unknown option: --nope") {
		t.Errorf("stderr = %q", f.err.String())
	}
}
