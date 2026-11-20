package command

import (
	"io"
	"reflect"
	"testing"
)

func noop(args []string, out, errOut io.Writer) int { return 0 }

func TestPortedEmpty(t *testing.T) {
	if got := Ported(); len(got) != 0 {
		t.Fatalf("Ported() = %v, want no command ported yet", got)
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
	want := []string{"alpha", "mid", "zeta"}
	if got := Ported(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Ported() = %v, want %v", got, want)
	}
}
