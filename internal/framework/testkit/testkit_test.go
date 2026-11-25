package testkit

import (
	"os"
	"testing"
)

func TestTempHome(t *testing.T) {
	dir := TempHome(t)
	if dir == "" || os.Getenv("HOME") != dir {
		t.Fatalf("home=%q dir=%q", os.Getenv("HOME"), dir)
	}
}

func TestFakeRunner(t *testing.T) {
	r := FakeRunner(t)
	if r == nil {
		t.Fatal("nil runner")
	}
}

func TestGolden(t *testing.T) {
	Golden(t, "golden.txt", "hello\n")
}
