package agent

import (
	"context"
	"sync"
	"testing"
)

// Two simultaneous rank_takes -> distinct starts (#289/#421); lock serializes.
func TestRankTakeParallel(t *testing.T) {
	state := t.TempDir()
	var mu sync.Mutex
	var starts []int
	var wg sync.WaitGroup
	excluded := func(string) bool { return true }
	n := 9
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			start, ok := RankTake(context.Background(), ExecRunner{}, state, "", RealClock{}, 1, n, nil, excluded)
			mu.Lock()
			if ok {
				starts = append(starts, start)
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(starts) != 2 {
		t.Fatal("not both took", starts)
	}
	if starts[0] == starts[1] {
		t.Fatal("same start", starts)
	}
	// rank advanced twice
	if got := readFileString(state + "/rang"); got == "" {
		t.Fatal("rang not written")
	}
}
