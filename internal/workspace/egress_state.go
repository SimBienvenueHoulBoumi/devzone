package workspace

import (
	"fmt"
	"regexp"
	"strings"
)

// egressBase is the base list of the chart (egressProxy.allowedDomains in
// values.yaml): allow cannot add it and deny cannot remove it.
const egressBase = ".opencode.ai .npmjs.org .github.com"

// egressDomainPattern is the shell rule: a lowercase domain with at least one
// dot, an optional leading dot for subdomains, no space, comma, star or slash.
var egressDomainPattern = regexp.MustCompile(`^\.?[a-z0-9-]+(\.[a-z0-9-]+)+$`)

// EgressParams returns the chart parameters replayed at each start and update,
// as egress_params in manage/scripts/workspace/workspace-egress.sh. Nothing is
// returned when the mode is off or unset: the chart is then unchanged.
func EgressParams(modules string) string {
	mode := readModulesKey(modules, "egress")
	if mode != "observation" && mode != "strict" {
		return ""
	}
	params := "egressProxy.enabled=true egressProxy.mode=" + mode
	if domains := readModulesKey(modules, "egress_domains"); domains != "" {
		params += " egressProxy.extraDomains=" + domains
	}
	return params
}

// EgressDomainOK tells whether domain can be added with allow.
func EgressDomainOK(domain string) bool {
	return egressDomainPattern.MatchString(domain)
}

// egressEdit computes an allow or deny without touching the state, so the
// caller can check the cluster before writing. It returns the line for the
// user, the new value of egress_domains and whether that value changed.
func egressEdit(action, domain, list string) (out, errOut, next string, changed bool, status int) {
	if !EgressDomainOK(domain) {
		return "", fmt.Sprintf("✖ domain not valid: %s (lowercase letters, digits, hyphens and dots, at least one dot, optional leading dot; no space, comma, * or /)\n", domain), "", false, 1
	}
	base := strings.Contains(" "+egressBase+" ", " "+domain+" ")
	present := strings.Contains(","+list+",", ","+domain+",")
	if action == "allow" {
		switch {
		case base:
			return fmt.Sprintf("ℹ %s is in the base list (egressProxy.allowedDomains): already allowed\n", domain), "", "", false, 0
		case present:
			return fmt.Sprintf("ℹ already allowed: %s\n", domain), "", "", false, 0
		default:
			if list != "" {
				next = list + "," + domain
			} else {
				next = domain
			}
			return "", "", next, true, 0
		}
	}
	switch {
	case base:
		return "", fmt.Sprintf("✖ %s is in the base list: change it in egressProxy.allowedDomains of the chart (nothing changed)\n", domain), "", false, 1
	case !present:
		return "", fmt.Sprintf("✖ %s was not added with allow: nothing changed\n", domain), "", false, 1
	default:
		var kept []string
		for _, item := range strings.Split(list, ",") {
			if item != domain {
				kept = append(kept, item)
			}
		}
		return "", "", strings.Join(kept, ","), true, 0
	}
}
