package e2e

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// stepModule enables the gitlab module when it is not active yet.
func stepModule(s *session) (int, string) {
	res, err := s.run(s.devzone, []string{"is-enabled", "gitlab"})
	if err == nil && res.Code == 0 {
		return 0, ""
	}
	res, err = s.run(s.devzone, []string{"enable", "gitlab"})
	if err != nil || res.Code != 0 {
		return 1, "devzone enable gitlab failed"
	}
	return 0, ""
}

// stepState checks that the module is ready and its runner online: without a
// runner, the pipeline would wait forever.
func stepState(s *session) (int, string) {
	res, err := s.run(s.devzone, []string{"gitlab", "status"})
	state := ""
	if err == nil {
		state = combined(res.Stdout, res.Stderr)
	}
	if !strings.Contains(state, "ready") {
		if state == "" {
			state = "unreadable"
		}
		return 1, fmt.Sprintf("state: %s", state)
	}
	if !strings.Contains(state, "runner online") {
		return 1, fmt.Sprintf("runner offline (%s)", state)
	}
	return 0, ""
}

// stepName checks the resolution of gitlab.localhost and both relays: curl and
// git over HTTP resolve *.localhost on the loopback without reading the hosts
// file, so the web and SSH relays must listen too.
func stepName(s *session) (int, string) {
	res, err := s.run("getent", []string{"hosts", "gitlab.localhost"})
	fields := strings.Fields(string(res.Stdout))
	ip := ""
	if err == nil && len(fields) > 0 {
		ip = fields[0]
	}
	if ip == "" {
		return 1, "gitlab.localhost not resolved (getent hosts)"
	}
	if ip != "127.0.0.1" {
		return 1, fmt.Sprintf("gitlab.localhost resolves to %s, expected 127.0.0.1", ip)
	}
	res, err = s.run(s.devzone, []string{"gitlab", "relay-status"})
	if err != nil || res.Code != 0 {
		relays := strings.TrimSpace(string(res.Stdout) + string(res.Stderr))
		if relays == "" {
			relays = "gitlab relay stopped"
		}
		return 1, fmt.Sprintf("gitlab.localhost points to 127.0.0.1, but %s", relays)
	}
	return 0, ""
}

// stepPipeline starts the pipeline of devzone/demo on main, then waits for a
// final state. The polling clock is injected, so a timeout test never waits.
func stepPipeline(s *session) (int, string) {
	if !s.readToken() {
		return 1, s.current
	}
	form := url.Values{"ref": {"main"}}
	data, err := s.api.call(http.MethodPost, "/projects/devzone%2Fdemo/pipeline", form)
	if err != nil {
		return 1, "creation of the pipeline of devzone/demo impossible"
	}
	id := jsonField(data, "id")
	web := jsonField(data, "web_url")
	if id == "" {
		return 1, "pipeline creation response without id"
	}
	if web == "" {
		web = s.api.base + "/devzone/demo/-/pipelines/" + id
	}
	start := s.now()
	for {
		data, err = s.api.call(http.MethodGet, "/projects/devzone%2Fdemo/pipelines/"+id, nil)
		status := ""
		if err == nil {
			status = jsonField(data, "status")
		}
		switch status {
		case "success":
			return 0, ""
		case "failed", "canceled", "skipped":
			return 1, fmt.Sprintf("pipeline %s: %s", status, web)
		}
		if int(s.now().Sub(start)/time.Second) >= s.timeout {
			return 1, fmt.Sprintf("timeout %d s exceeded (state %s): %s", s.timeout, defaultReason(status), web)
		}
		s.sleep(time.Duration(s.interval) * time.Second)
	}
}
