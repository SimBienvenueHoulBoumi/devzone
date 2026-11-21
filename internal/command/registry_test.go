package command

import (
	"io"
	"reflect"
	"testing"
)

func noop(args []string, out, errOut io.Writer) int { return 0 }

func TestPortedCommands(t *testing.T) {
	want := []string{"--help", "--version", "-h", "-v", "help", "workspace"}
	if got := Ported(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Ported() = %v, want %v", got, want)
	}
}

func TestPortedSorted(t *testing.T) {
	names := []string{"zeta", "alpha", "mid"}
	for _, name := range names {
		ported[name] = noop
	}
	t.Cleanup(func() {
		for _, name := range names {
			delete(ported, name)
		}
	})
	want := []string{"--help", "--version", "-h", "-v", "alpha", "help", "mid", "workspace", "zeta"}
	if got := Ported(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Ported() = %v, want %v", got, want)
	}
}
