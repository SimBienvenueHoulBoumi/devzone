package agent

import (
	"context"
	"testing"
	"time"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

func TestNetworkReachable(t *testing.T) {
	r := fake.New()
	r.On("getent", []string{"hosts", "opencode.ai"}, dzexec.Result{Code: 0})
	r.On("curl", []string{"-sI", "--max-time", "5", "https://opencode.ai"}, dzexec.Result{Code: 0})
	if !NetworkReachable(context.Background(), r) {
		t.Fatal("reachable")
	}
	r2 := fake.New()
	r2.On("getent", []string{"hosts", "opencode.ai"}, dzexec.Result{Code: 2})
	if NetworkReachable(context.Background(), r2) {
		t.Fatal("getent fail still reachable")
	}
	r3 := fake.New()
	r3.On("getent", []string{"hosts", "opencode.ai"}, dzexec.Result{Code: 0})
	r3.On("curl", []string{"-sI", "--max-time", "5", "https://opencode.ai"}, dzexec.Result{Code: 1})
	if NetworkReachable(context.Background(), r3) {
		t.Fatal("curl fail still reachable")
	}
}

func TestNetworkWait(t *testing.T) {
	clock := &FakeClock{NowTime: time0()}
	// fake runner where network recovers
	recover := &recoverRunner{}
	journal := t.TempDir() + "/j.log"
	if !NetworkWait(context.Background(), recover, clock, journal) {
		t.Fatal("network not back")
	}
	j := readFileString(journal)
	if !containsStr(j, "=== network down, waiting") || !containsStr(j, "=== network back") {
		t.Fatal("no lines", j)
	}
}

func TestNetworkWaitTimeout(t *testing.T) {
	clock := &FakeClock{NowTime: time0()}
	t.Setenv("DEVZONE_AGENT_NETWORK_MAX", "2")
	r := fake.New() // getent/curl default code 1
	if NetworkWait(context.Background(), r, clock, t.TempDir()+"/j.log") {
		t.Fatal("network back when down")
	}
}

type recoverRunner struct{ n int }

func (r *recoverRunner) Run(ctx context.Context, name string, args []string, opts dzexec.Opts) (dzexec.Result, error) {
	if name == "getent" {
		if r.n == 0 {
			r.n++
			return dzexec.Result{Code: 2}, nil
		}
		return dzexec.Result{Code: 0}, nil
	}
	if name == "curl" {
		return dzexec.Result{Code: 0}, nil
	}
	return dzexec.Result{Code: 0}, nil
}

func time0() time.Time { return time.Unix(1700000000, 0) }
