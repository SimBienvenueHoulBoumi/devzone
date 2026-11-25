package kube

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// TestTokenFreshTrueWhenMoreThanOneHourRemains checks the freshness of the
// token when the expiry is more than one hour away.
func TestTokenFreshTrueWhenMoreThanOneHourRemains(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", path)
	if err := os.WriteFile(path, []byte(strconv.FormatInt(time.Now().Unix()+7200, 10)), 0o600); err != nil {
		t.Fatal(err)
	}
	api := Kube{}
	if !api.TokenFresh() {
		t.Fatal("TokenFresh = false, want true")
	}
}

// TestTokenFreshFalseWhenLessThanOneHourRemains checks the freshness of the
// token when less than one hour remains.
func TestTokenFreshFalseWhenLessThanOneHourRemains(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", path)
	if err := os.WriteFile(path, []byte(strconv.FormatInt(time.Now().Unix()+1800, 10)), 0o600); err != nil {
		t.Fatal(err)
	}
	api := Kube{}
	if api.TokenFresh() {
		t.Fatal("TokenFresh = true, want false")
	}
}

// TestTokenFreshFalseWhenExpired checks the freshness of the token once
// expired.
func TestTokenFreshFalseWhenExpired(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", path)
	if err := os.WriteFile(path, []byte(strconv.FormatInt(time.Now().Unix()-10, 10)), 0o600); err != nil {
		t.Fatal(err)
	}
	api := Kube{}
	if api.TokenFresh() {
		t.Fatal("TokenFresh = true, want false")
	}
}

// TestTokenFreshFalseWhenFileUnreadable checks the freshness without a
// readable expiry file: absent, empty or non-numeric content is not fresh.
func TestTokenFreshFalseWhenFileUnreadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", path)
	api := Kube{}
	if api.TokenFresh() {
		t.Fatal("TokenFresh = true for an absent file, want false")
	}
	for _, content := range []string{"", "not-a-number", "+1893456000"} {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if api.TokenFresh() {
			t.Fatalf("TokenFresh = true for %q, want false", content)
		}
	}
}

// TestExpiryEpoch checks the epoch seconds of a TokenRequest timestamp, and
// the fallback when it cannot be read.
func TestExpiryEpoch(t *testing.T) {
	k := Kube{}
	epoch, ok := k.ExpiryEpoch("2030-01-01T00:00:00Z")
	if !ok || epoch != 1893456000 {
		t.Fatalf("ExpiryEpoch = %d, %v; want 1893456000, true", epoch, ok)
	}
	if epoch, ok := k.ExpiryEpoch("not-a-timestamp"); ok || epoch != 0 {
		t.Fatalf("ExpiryEpoch = %d, %v; want 0, false", epoch, ok)
	}
}
