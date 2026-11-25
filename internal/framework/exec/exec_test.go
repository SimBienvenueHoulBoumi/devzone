package exec

import (
	"context"
	"testing"
)

func TestExecRunnerTrueFalse(t *testing.T) {
	r := ExecRunner{}
	res, err := r.Run(context.Background(), "true", nil, Opts{})
	if err != nil || res.Code != 0 {
		t.Fatalf("true: %v %d", err, res.Code)
	}
	res, err = r.Run(context.Background(), "false", nil, Opts{})
	if err != nil || res.Code != 1 {
		t.Fatalf("false: %v %d", err, res.Code)
	}
	if _, err := r.Run(context.Background(), "/no/such/binary", nil, Opts{}); err == nil {
		t.Fatal("expected error for missing binary")
	}
}
