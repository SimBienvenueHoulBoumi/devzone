package podcmd

import "testing"

// TestParseTicketValid checks that the valid command lines parse into the expected requests.
func TestParseTicketValid(t *testing.T) {
	tests := []struct {
		args []string
		done bool
		n    string
		repo string
	}{
		{[]string{"12"}, false, "12", "devzone"},
		{[]string{"done", "12"}, true, "12", "devzone"},
		{[]string{"12", "--repo", "repowarden"}, false, "12", "repowarden"},
		{[]string{"done", "12", "--repo", "repowarden"}, true, "12", "repowarden"},
		{[]string{"--repo", "repowarden", "12"}, false, "12", "repowarden"},
		{[]string{"", "12"}, false, "12", "devzone"},
	}
	for _, c := range tests {
		req, err := parseTicket(c.args)
		if err != nil {
			t.Errorf("parseTicket(%v) error = %v", c.args, err)
			continue
		}
		if req.done != c.done {
			t.Errorf("parseTicket(%v).done = %v, want %v", c.args, req.done, c.done)
		}
		if req.n != c.n {
			t.Errorf("parseTicket(%v).n = %q, want %q", c.args, req.n, c.n)
		}
		if req.repo != c.repo {
			t.Errorf("parseTicket(%v).repo = %q, want %q", c.args, req.repo, c.repo)
		}
	}
}

// TestParseTicketUsage checks that the invalid command lines return errTicketUsage.
func TestParseTicketUsage(t *testing.T) {
	usages := [][]string{
		{},
		{"abc"},
		{"12", "34"},
		{"--repo"},
		{"12", "--bad"},
		{"-x", "12"},
		{"done"},
		{"12", "done"},
		{"1a"},
		{" 5"},
		{"+5"},
		{"1-2"},
		{""},
		{"12", ""},
		{"done", "--repo", "repowarden"},
	}
	for _, args := range usages {
		if _, err := parseTicket(args); err != errTicketUsage {
			t.Errorf("parseTicket(%v) error = %v, want errTicketUsage", args, err)
		}
	}
}
