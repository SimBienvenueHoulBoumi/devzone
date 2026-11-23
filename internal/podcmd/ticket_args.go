package podcmd

import (
	"errors"
	"strings"
)

// ticketRequest is the parsed command line of "devzone ticket".
type ticketRequest struct {
	done bool
	n    string
	repo string
}

// errTicketUsage tells that the command line is wrong: the usage is printed, status 1.
var errTicketUsage = errors.New("ticket usage")

// parseTicket reads the arguments of "devzone ticket": [done] <n> [--repo <name>] …
func parseTicket(args []string) (ticketRequest, error) {
	req := ticketRequest{repo: "devzone"}
	if len(args) > 0 && args[0] == "done" {
		req.done = true
		args = args[1:]
	}
	for i := 0; i < len(args); {
		switch {
		case args[i] == "--repo":
			if i+1 >= len(args) {
				return req, errTicketUsage
			}
			req.repo = args[i+1]
			i += 2
		case strings.HasPrefix(args[i], "-"):
			return req, errTicketUsage
		default:
			if req.n != "" {
				return req, errTicketUsage
			}
			req.n = args[i]
			i++
		}
	}
	if req.n == "" {
		return req, errTicketUsage
	}
	for i := 0; i < len(req.n); i++ {
		if req.n[i] < '0' || req.n[i] > '9' {
			return req, errTicketUsage
		}
	}
	return req, nil
}
