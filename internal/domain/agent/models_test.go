package agent

import (
	"context"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

func TestFreeModelsDefaultNoDuplicate(t *testing.T) {
	seen := map[string]bool{}
	for _, m := range FreeModelsDefault {
		if seen[m] {
			t.Fatal("duplicate", m)
		}
		seen[m] = true
	}
	if len(FreeModelsDefault) != 9 {
		t.Fatal("len", len(FreeModelsDefault))
	}
}

func TestListModels(t *testing.T) {
	r := fake.New()
	r.On("opencode", []string{"models", "opencode"}, execResult("opencode/big-pickle\nopencode/x-free\nopencode/y-free\nopencode/notfree\ndup\nopencode/big-pickle\n", 0))
	got := ListModels(context.Background(), r, nil)
	if len(got) != 3 || got[0] != "big-pickle" || got[1] != "x-free" || got[2] != "y-free" {
		t.Fatal("list", got)
	}
}

func TestListModelsFallback(t *testing.T) {
	r := fake.New()
	r.On("opencode", []string{"models", "opencode"}, execResult("", 1))
	if got := ListModels(context.Background(), r, []string{"fallback"}); len(got) != 1 || got[0] != "fallback" {
		t.Fatal("fallback", got)
	}
}

func TestInternalName(t *testing.T) {
	if InternalName("hf.co/org/model:tag") != "hf.co_org_model_tag" {
		t.Fatal(InternalName("hf.co/org/model:tag"))
	}
	if InternalName("a b") != "a_b" {
		t.Fatal("space")
	}
}

func TestModelAtRank(t *testing.T) {
	free := []string{"a", "b", "c"}
	if ModelAtRank(0, 1, free, "local") != "b" {
		t.Fatal("rotation")
	}
	if ModelAtRank(3, 0, free, "local") != "local" {
		t.Fatal("local last")
	}
	if ModelsTotal(free, "local") != 4 {
		t.Fatal("total")
	}
	if ModelsTotal(free, "") != 3 {
		t.Fatal("total no local")
	}
}

func TestModelOrder(t *testing.T) {
	free := []string{"a", "b", "c"}
	atRank := func(rank int) string { return ModelAtRank(rank, 0, free, "") }
	// requested first, no duplicate in rotation
	order := ModelOrder(0, []string{"b"}, 3, atRank)
	if len(order) != 3 || order[0] != "b" {
		t.Fatal("order", order)
	}
	// requested appears once
	cnt := 0
	for _, m := range order {
		if m == "b" {
			cnt++
		}
	}
	if cnt != 1 {
		t.Fatal("dup", order)
	}
}

func execResult(stdout string, code int) dzexec.Result {
	return dzexec.Result{Stdout: []byte(stdout), Code: code}
}
