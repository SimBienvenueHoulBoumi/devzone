package workspace

import (
	"testing"
)

// TestParseStatKeepsZombiesOnly checks that only the zombie state is reported,
// and that a command name holding spaces or parentheses is read whole.
func TestParseStatKeepsZombiesOnly(t *testing.T) {
	cases := []struct {
		name string
		pid  int
		stat string
		want Zombie
		ok   bool
	}{
		{"plain zombie", 7, "7 (sh) Z 3 0 0 0", Zombie{PID: 7, PPID: 3, Name: "sh"}, true},
		{"name with spaces and parentheses", 8, "8 (my (odd) name) Z 5 0 0", Zombie{PID: 8, PPID: 5, Name: "my (odd) name"}, true},
		{"sleeping process", 9, "9 (x) S 1 0 0", Zombie{}, false},
		{"running process", 10, "10 (y) R 1 0 0", Zombie{}, false},
		{"no closing parenthesis", 11, "11 (z S 1", Zombie{}, false},
		{"truncated", 12, "12 (w) Z", Zombie{}, false},
		{"non numeric parent", 13, "13 (v) Z abc 0", Zombie{}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := parseStat(c.pid, c.stat)
			if ok != c.ok {
				t.Fatalf("parseStat(%q) ok = %v, want %v", c.stat, ok, c.ok)
			}
			if ok && got != c.want {
				t.Fatalf("parseStat(%q) = %+v, want %+v", c.stat, got, c.want)
			}
		})
	}
}

// TestPid1BlindOnlyWithoutWait checks the test on PID 1's command line: the old
// "sleep infinity" is blind, the new loop that calls wait is not.
func TestPid1BlindOnlyWithoutWait(t *testing.T) {
	cases := map[string]bool{
		"sleep infinity": true,
		"bash -c mkdir -p x; while true; do wait -n 2>/dev/null; sleep 1; done": false,
		// The rule is textual: a wrapper around "sleep infinity" is reported too,
		// even when that wrapper reaps. Known limit, stated in pid1Blind.
		"/usr/bin/tini -- sleep infinity": true,
		"bash":                            false,
		"":                                false,
	}
	for cmdline, want := range cases {
		if got := pid1Blind(cmdline); got != want {
			t.Errorf("pid1Blind(%q) = %v, want %v", cmdline, got, want)
		}
	}
}

// TestGroupZombiesLargestFirst checks the grouping: the largest group comes first,
// ties by parent pid, and each group keeps the name the caller gave.
func TestGroupZombiesLargestFirst(t *testing.T) {
	zombies := []Zombie{
		{PID: 10, PPID: 50}, {PID: 11, PPID: 1}, {PID: 12, PPID: 1},
		{PID: 13, PPID: 7}, {PID: 14, PPID: 1}, {PID: 15, PPID: 7},
	}
	names := map[int]string{1: "sleep", 7: "bash", 50: "opencode"}
	groups := groupZombies(zombies, func(pid int) string { return names[pid] })
	want := []ParentGroup{
		{PPID: 1, Name: "sleep", Count: 3},
		{PPID: 7, Name: "bash", Count: 2},
		{PPID: 50, Name: "opencode", Count: 1},
	}
	if len(groups) != len(want) {
		t.Fatalf("groups = %+v, want %+v", groups, want)
	}
	for i := range want {
		if groups[i] != want[i] {
			t.Fatalf("group %d = %+v, want %+v", i, groups[i], want[i])
		}
	}
}
