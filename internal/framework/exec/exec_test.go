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

// TestExecRunnerEnvIsAddedNotReplaced checks that Opts.Env is added to the
// environment of the process: HOME and the other variables stay visible (#863:
// without HOME, kubectl wrote its cache in the current folder).
func TestExecRunnerEnvIsAddedNotReplaced(t *testing.T) {
	t.Setenv("DEVZONE_EXEC_PARENT", "parent")
	r := ExecRunner{}
	res, err := r.Run(context.Background(), "sh",
		[]string{"-c", `printf '%s|%s' "$DEVZONE_EXEC_PARENT" "$DEVZONE_EXEC_ADDED"`},
		Opts{Env: []string{"DEVZONE_EXEC_ADDED=added"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(res.Stdout); got != "parent|added" {
		t.Fatalf("stdout = %q, want %q", got, "parent|added")
	}
}
