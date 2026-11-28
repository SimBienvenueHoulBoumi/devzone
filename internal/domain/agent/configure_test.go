package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func devcontainerDir(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	d := filepath.Join(wd, "..", "..", "..", ".devcontainer")
	if _, err := os.Stat(filepath.Join(d, "opencode", "agent.json")); err != nil {
		t.Fatal("no agent.json", err)
	}
	return d
}

func TestConfigureDefault(t *testing.T) {
	out, err := Configure(devcontainerDir(t), "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"git push*":"deny"`) {
		t.Fatal("git push not denied", out)
	}
	if !strings.Contains(out, `"git commit*":"allow"`) {
		t.Fatal("git commit not allowed")
	}
	if !strings.Contains(out, `"ln *bash32*":"deny"`) {
		t.Fatal("bash32 not denied")
	}
	if !strings.Contains(out, `"internal/domain/agent/rights.go":"deny"`) {
		t.Fatal("rights.go not protected", out)
	}
	// 8 rights denies on permission.edit last
	cfg, _ := ParseJSON([]byte(out))
	edit := cfg.Get("permission").Get("edit").Obj()
	if len(edit) < 8 {
		t.Fatal("edit deny missing", out)
	}
	for i := len(edit) - 8; i < len(edit); i++ {
		if edit[i].Value.Str() != "deny" {
			t.Fatal("deny not last", out)
		}
	}
}

func TestConfigureCallerCannotRemoveDeny(t *testing.T) {
	env := `{"permission":{"bash":{"*":"allow","git push*":"allow"},"edit":"allow"}}`
	out, err := Configure(devcontainerDir(t), env)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"git push*":"deny"`) {
		t.Fatal("git push deny removed", out)
	}
	if !strings.Contains(out, `"*":"allow"`) {
		t.Fatal("caller allow lost", out)
	}
	// order: * before git push* deny
	cfg, _ := ParseJSON([]byte(out))
	keys := cfg.Get("permission").Get("bash").Keys()
	star, push := -1, -1
	for i, k := range keys {
		if k == "*" {
			star = i
		}
		if k == "git push*" {
			push = i
		}
	}
	if !(star < push) {
		t.Fatal("* not before git push*", keys)
	}
}

func TestConfigureBadJSON(t *testing.T) {
	if _, err := Configure(devcontainerDir(t), "{not json"); err == nil {
		t.Fatal("bad env json accepted")
	}
}

// gh reads permitted, writes/secrets denied (agent-rights-gh).
func TestConfigureGh(t *testing.T) {
	out, err := Configure(devcontainerDir(t), "")
	if err != nil {
		t.Fatal(err)
	}
	cfg, _ := ParseJSON([]byte(out))
	bash := cfg.Get("permission").Get("bash")
	perm := func(cmd string) string {
		keys := bash.Keys()
		best := ""
		for _, k := range keys {
			if matchGlob(k, cmd) {
				best = bash.Get(k).Str()
			}
		}
		return best
	}
	for _, c := range []string{"gh issue view 1 --comments", "gh pr checks 2", "gh run view 3"} {
		if perm(c) != "allow" {
			t.Fatal("gh read denied", c, perm(c))
		}
	}
	for _, c := range []string{"gh issue create", "gh issue comment", "gh pr merge", "gh api repos", "gh workflow run", "gh release create", "gh auth token"} {
		if perm(c) != "deny" {
			t.Fatal("gh write not denied", c, perm(c))
		}
	}
}

func matchGlob(pattern, s string) bool {
	// opencode matching: '*' wildcard, ' ' separated prefix; simple check for test
	if pattern == "*" {
		return true
	}
	if strings.HasSuffix(pattern, "*") {
		return strings.HasPrefix(s, strings.TrimSuffix(pattern, "*"))
	}
	return pattern == s || strings.HasPrefix(s, pattern+" ")
}
