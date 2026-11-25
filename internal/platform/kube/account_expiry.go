package kube

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// tokenFreshness is the margin under which a token is considered fresh: a token
// expiring within one hour is renewed.
const tokenFreshness = 3600

// TokenFresh reports whether the token of the limited account is fresh, by
// reading the expiry file without any network call. Absent, unreadable,
// non-numeric, close or past expiry → false.
func (k Kube) TokenFresh() bool {
	return tokenFresh(tokenExpiryPath())
}

// tokenFresh reads the expiry file and reports whether the token has more than
// one hour left.
func tokenFresh(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		return false
	}
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	epoch, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return false
	}
	return epoch > time.Now().Unix()+tokenFreshness
}

// ExpiryEpoch returns the Unix epoch seconds of the RFC 3339 expiration
// timestamp of a TokenRequest response; ok is false when it cannot be read, so
// the caller falls back to now + 24 h.
func (k Kube) ExpiryEpoch(timestamp string) (int64, bool) {
	parsed, err := time.Parse(time.RFC3339, timestamp)
	if err != nil {
		return 0, false
	}
	return parsed.Unix(), true
}
