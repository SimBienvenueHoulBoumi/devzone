package clustermenu

import (
	"strings"
	"testing"
)

// TestOfferEmptyCancels: an empty choice cancels, nothing runs
func TestOfferEmptyCancels(t *testing.T) {
	f := newFixture("\n", true)
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false on an empty choice")
	}
	if !strings.Contains(f.out.String(), "Your choice") || f.errOut.String() != "✖ cancelled\n" {
		t.Fatalf("out = %q, err = %q", f.out.String(), f.errOut.String())
	}
	if len(f.runner.Calls()) != 0 {
		t.Fatalf("calls = %+v, want none", f.runner.Calls())
	}
}

// TestOfferUnknownChoiceCancels: any other answer than 1 or 2 cancels
func TestOfferUnknownChoiceCancels(t *testing.T) {
	f := newFixture("3\n", true)
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false for choice 3")
	}
	if f.errOut.String() != "✖ cancelled\n" {
		t.Fatalf("err = %q", f.errOut.String())
	}
}

// TestOfferAnswerCutByEndOfInput: a last answer without its newline is empty, as read fails on it in the shell
func TestOfferAnswerCutByEndOfInput(t *testing.T) {
	f := newFixture("2", true)
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false when the answer is cut by the end of input")
	}
	if f.errOut.String() != "✖ cancelled\n" {
		t.Fatalf("err = %q, want the cancel message", f.errOut.String())
	}
}

// TestOfferListsBothChoices: the menu shows the remote and the minikube choices
func TestOfferListsBothChoices(t *testing.T) {
	f := newFixture("\n", true)
	f.menu.Offer()
	for _, want := range []string{"No Kubernetes cluster answers. Pick one:", "  1) a remote cluster", "  2) a local minikube cluster (profile devzone)"} {
		if !strings.Contains(f.out.String(), want) {
			t.Fatalf("menu lacks %q: %q", want, f.out.String())
		}
	}
}
