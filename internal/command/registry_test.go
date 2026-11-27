package command

import (
	"reflect"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

func noop(ctx *cli.Context) int { return 0 }

func TestPortedCommands(t *testing.T) {
	want := []string{"--help", "--version", "-h", "-v", "cluster-offer", "create-mode", "create-workstation", "help", "host-check", "kube-ready", "uninstall", "update", "workspace"}
	if got := Ported(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Ported() = %v, want %v", got, want)
	}
}

func TestPortedSorted(t *testing.T) {
	for _, name := range []string{"zeta", "alpha", "mid"} {
		Registry.Register(cli.Command{Name: name, Run: noop})
	}
	t.Cleanup(func() {
		// rebuild registry to original state
		Registry = newDefaultRegistry()
	})
	want := []string{"--help", "--version", "-h", "-v", "alpha", "cluster-offer", "create-mode", "create-workstation", "help", "host-check", "kube-ready", "mid", "uninstall", "update", "workspace", "zeta"}
	if got := Ported(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Ported() = %v, want %v", got, want)
	}
}
