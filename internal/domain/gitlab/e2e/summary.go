package e2e

import (
	"fmt"
	"strings"
)

// summary writes one line per step and the total, as the shell summary did.
func summary(s *session, results []result, total int) {
	ok, failed, skipped := 0, 0, 0
	s.out("\ndevzone test-gitlab : summary\n")
	for _, r := range results {
		s.out("  %s %-28s %3d s%s\n", r.symbol, r.name, r.duration, r.suffix)
		switch r.symbol {
		case "✔":
			ok++
		case "✖":
			failed++
		default:
			skipped++
		}
	}
	s.out("  total: %d step(s), %d s, %d ✔, %d ✖, %d skipped\n", len(results), total, ok, failed, skipped)
}

// shortSummary builds the description of the GitHub status: no secret, under
// 140 characters, with the first failed step when there is one.
func shortSummary(results []result, total int) string {
	ok, failed, skipped := 0, 0, 0
	firstFailed := ""
	for _, r := range results {
		switch r.symbol {
		case "✔":
			ok++
		case "✖":
			failed++
			if firstFailed == "" {
				firstFailed = r.name
			}
		default:
			skipped++
		}
	}
	if failed > 0 {
		return fmt.Sprintf("%d ✔, %d ✖ (%s), %d skipped — %d s", ok, failed, firstFailed, skipped, total)
	}
	return fmt.Sprintf("%d ✔, %d skipped — %d s", ok, skipped, total)
}

// publishStatus publishes the result on HEAD through the API of gh, with the
// maintainer token. Without a login or a repository, it refuses clearly.
func publishStatus(s *session, results []result, total int) int {
	res, err := s.run("gh", []string{"auth", "status"})
	if err != nil || res.Code != 0 {
		s.errOut("devzone test-gitlab : gh not logged in, gitlab-integration status not published (gh auth login -s workflow)\n")
		return 1
	}
	res, err = s.run("gh", []string{"repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"})
	repo := strings.TrimSpace(string(res.Stdout))
	if err != nil || res.Code != 0 || repo == "" {
		s.errOut("devzone test-gitlab : current GitHub repository not found, status not published\n")
		return 1
	}
	res, err = s.run("git", []string{"rev-parse", "HEAD"})
	sha := strings.TrimSpace(string(res.Stdout))
	if err != nil || res.Code != 0 || sha == "" {
		s.errOut("devzone test-gitlab : HEAD commit not found, status not published\n")
		return 1
	}
	failed := false
	for _, r := range results {
		if r.symbol == "✖" {
			failed = true
		}
	}
	state := "success"
	if failed {
		state = "failure"
	}
	description := shortSummary(results, total)
	_, err = s.run("gh", []string{"api", "-X", "POST", "repos/" + repo + "/statuses/" + sha,
		"-f", "state=" + state, "-f", "context=gitlab-integration", "-f", "description=" + description})
	if err != nil {
		s.errOut("devzone test-gitlab : publishing the gitlab-integration status impossible\n")
		return 1
	}
	s.out("devzone test-gitlab : gitlab-integration status (%s) published on %s@%s\n", state, repo, sha)
	return 0
}
