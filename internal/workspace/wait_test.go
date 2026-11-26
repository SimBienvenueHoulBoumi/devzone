package workspace

import (
	"bytes"
	"io"
	"strings"
	"testing"
	"time"
)

// scriptedRunner answers each successive kubectl call from a list, and records
// the calls: it lets a wait see a revision change without a real cluster.
type scriptedRunner struct {
	answers []string
	calls   []string
}

// Kubectl returns the next answer, or an empty one when the list is exhausted.
func (s *scriptedRunner) Kubectl(args []string, _ io.Reader, out, _ io.Writer) (int, error) {
	line := strings.Join(args, " ")
	s.calls = append(s.calls, line)
	if strings.Contains(line, "config get-contexts") {
		return 0, nil
	}
	if len(s.answers) > 0 {
		answer := s.answers[0]
		s.answers = s.answers[1:]
		_, _ = io.WriteString(out, answer)
	}
	return 0, nil
}

// Helm is unused by a wait.
func (s *scriptedRunner) Helm(_ []string, _ io.Reader, _, _ io.Writer) (int, error) {
	return 0, nil
}

// fakeClock advances only when the wait sleeps, so a test never waits for a
// real timeout.
type fakeClock struct {
	now   time.Time
	step  time.Duration
	sleep func(time.Duration)
}

// newFakeClock returns a clock whose sleeps move time forward by step.
func newFakeClock(step time.Duration) *fakeClock {
	c := &fakeClock{now: time.Unix(0, 0), step: step}
	c.sleep = func(d time.Duration) { c.now = c.now.Add(d) }
	return c
}

// TestWaitForPodRunning checks that a matching revision and a Running pod end
// the wait at once, without undeploying anything.
func TestWaitForPodRunning(t *testing.T) {
	r := &scriptedRunner{answers: []string{"rev1", "rev1", "Running"}}
	clock := newFakeClock(time.Second)
	env := waitEnv{runner: r, timeout: 10 * time.Second, step: time.Second,
		sleep: clock.sleep, start: func() time.Time { return clock.now }, undeploy: func() int { t.Fatal("undeploy called"); return 0 }}
	var out, errOut bytes.Buffer
	env.out, env.errOut = &out, &errOut
	if status := env.wait("ghcr.io/dev:1.2.3"); status != 0 {
		t.Fatalf("status = %d", status)
	}
	if out.String() != "✔ workspace started (ghcr.io/dev:1.2.3)\n" || errOut.Len() != 0 {
		t.Fatalf("out = %q, errOut = %q", out.String(), errOut.String())
	}
	if !strings.Contains(r.calls[len(r.calls)-1], "status.phase") {
		t.Fatalf("last kubectl call = %q", r.calls[len(r.calls)-1])
	}
}

// TestWaitForPodWaitsForTheNewRevision checks that an old pod is not accepted
// as ready before the StatefulSet revision matches it.
func TestWaitForPodWaitsForTheNewRevision(t *testing.T) {
	r := &scriptedRunner{answers: []string{"rev2", "rev1", "", "", "rev2", "rev2", "Running"}}
	clock := newFakeClock(time.Second)
	env := waitEnv{runner: r, timeout: 10 * time.Second, step: time.Second,
		sleep: clock.sleep, start: func() time.Time { return clock.now }, undeploy: func() int { return 0 }}
	var out, errOut bytes.Buffer
	env.out, env.errOut = &out, &errOut
	if status := env.wait("image"); status != 0 {
		t.Fatalf("status = %d", status)
	}
	if !strings.Contains(out.String(), "✔ workspace started") {
		t.Fatalf("output = %q", out.String())
	}
	if elapsed := clock.now.Sub(time.Unix(0, 0)); elapsed != 2*time.Second {
		t.Fatalf("waited %v, want 2 s", elapsed)
	}
}

// TestWaitForPodImageFailures checks the two messages of a failed pull and
// that the workspace is undeployed so selfHeal cannot recreate the bad pod.
func TestWaitForPodImageFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		events string
		want   string
	}{
		{"not found", "Error response from daemon", "✖ image repo:1 not found: it is published at each devzone release.\n"},
		{"no build", "no match for platform in manifest", "✖ image repo:1 has no build for arm64: devzone releases publish it for amd64 and arm64.\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &scriptedRunner{answers: []string{"r", "r", "Pending ImagePullBackOff", tc.events, "arm64"}}
			env := waitEnv{runner: r, timeout: 10 * time.Second, step: time.Second,
				sleep: func(time.Duration) {}, start: func() time.Time { return time.Time{} }}
			called := 0
			env.undeploy = func() int { called++; return 0 }
			var out, errOut bytes.Buffer
			env.out, env.errOut = &out, &errOut
			if status := env.wait("repo:1"); status != 1 {
				t.Fatalf("status = %d, want 1", status)
			}
			want := tc.want + "  For a manually built image: devzone workspace start --image <repository:tag>\n"
			if errOut.String() != want {
				t.Fatalf("errOut = %q, want %q", errOut.String(), want)
			}
			if called != 1 {
				t.Fatalf("undeploy called %d times", called)
			}
		})
	}
}

// TestWaitForPodTimeout checks that a pod still starting when the bound is
// reached is only reported, as the shell does, with status 0.
func TestWaitForPodTimeout(t *testing.T) {
	r := &scriptedRunner{answers: []string{"r", "r", "Pending"}}
	clock := newFakeClock(time.Second)
	env := waitEnv{runner: r, timeout: 2 * time.Second, step: time.Second,
		sleep: clock.sleep, start: func() time.Time { return clock.now }, undeploy: func() int { t.Fatal("undeploy called"); return 0 }}
	var out, errOut bytes.Buffer
	env.out, env.errOut = &out, &errOut
	if status := env.wait("repo:1"); status != 0 {
		t.Fatalf("status = %d", status)
	}
	if errOut.String() != "⚠ pod not ready after 2 s: devzone workspace status\n" {
		t.Fatalf("errOut = %q", errOut.String())
	}
}

// TestWaitSecondsDefaults checks the environment parsing of the two bounds.
func TestWaitSecondsDefaults(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE_WAIT", "45")
	t.Setenv("DEVZONE_WORKSPACE_STEP", "nope")
	if got := waitSeconds("DEVZONE_WORKSPACE_WAIT", 120); got != 45*time.Second {
		t.Fatalf("wait = %v", got)
	}
	if got := waitSeconds("DEVZONE_WORKSPACE_STEP", 2); got != 2*time.Second {
		t.Fatalf("step = %v", got)
	}
}
