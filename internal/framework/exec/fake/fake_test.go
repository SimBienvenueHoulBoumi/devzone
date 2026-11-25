package fake

import (
	"context"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

func TestFakeRunnerResponseAndLog(t *testing.T) {
	r := New()
	r.On("git", []string{"status"}, exec.Result{Stdout: []byte("clean\n"), Code: 0})
	res, err := r.Run(context.Background(), "git", []string{"status"}, exec.Opts{})
	if err != nil || res.Code != 0 || string(res.Stdout) != "clean\n" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if len(r.Calls()) != 1 {
		t.Fatalf("calls=%d", len(r.Calls()))
	}
}
