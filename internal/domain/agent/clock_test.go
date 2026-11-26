package agent

import (
	"testing"
	"time"
)

// FakeClock is an injectable Clock with manual time; no real waiting.
type FakeClock struct {
	NowTime time.Time
	Sleeps  []time.Duration
}

// Now returns current fake time.
func (f *FakeClock) Now() time.Time { return f.NowTime }

// Sleep advances time, records.
func (f *FakeClock) Sleep(d time.Duration) {
	f.Sleeps = append(f.Sleeps, d)
	f.NowTime = f.NowTime.Add(d)
}

func testClock(t *testing.T) *FakeClock {
	t.Helper()
	return &FakeClock{NowTime: time.Unix(1700000000, 0)}
}
