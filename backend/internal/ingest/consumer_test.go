package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

var testLimits = Limits{MaxBytes: 1024 * 1024, MaxMessages: 1000, MaxPayloadBytes: 4096}

func openTest(t *testing.T, path string, limits Limits) *Spool {
	t.Helper()
	s, err := Open(path, limits)
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func eventually(t *testing.T, fn func() bool) {
	t.Helper()
	until := time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		if fn() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not reached")
}

func TestSpoolRestartRetainsIdentityAndDeadLettersCountAgainstBudget(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	limits := testLimits
	limits.MaxMessages = 2
	s := openTest(t, path, limits)
	p, err := s.Append("chat/one", []byte("bad input"))
	if err != nil {
		t.Fatal(err)
	}
	key, original, err := s.Peek(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path, limits); err == nil {
		t.Fatal("two processes can open one spool")
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s = openTest(t, path, limits)
	defer s.Close()
	key2, replay, err := s.Peek(p)
	if err != nil || string(key2) != string(key) || replay.ID != original.ID || !replay.ReceivedAt.Equal(original.ReceivedAt) {
		t.Fatal("replay identity changed", err)
	}
	if err := s.Finish(p, key, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Append("chat/two", []byte("next")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Append("chat/three", []byte("overflow")); !errors.Is(err, ErrFull) {
		t.Fatal("dead letter bypassed capacity", err)
	}
	stats, err := s.Stats()
	if err != nil || stats.Dead != 1 || stats.Pending != 1 || stats.Bytes <= 0 {
		t.Fatal(stats, err)
	}
	var exported bytes.Buffer
	if err := s.ExportDead(&exported); err != nil {
		t.Fatal(err)
	}
	var decoded Record
	if err := json.Unmarshal(exported.Bytes(), &decoded); err != nil || decoded.ID != original.ID {
		t.Fatal("export lost record", err)
	}
	if err := s.ResolveDead(true); err != nil {
		t.Fatal(err)
	}
	requeued, _ := s.Stats()
	if requeued.Pending != 2 || requeued.Dead != 0 || requeued.Bytes != stats.Bytes {
		t.Fatal("replay changed accounting", requeued)
	}
	if err := s.Finish(p, key, true); err != nil {
		t.Fatal(err)
	}
	if err := s.ResolveDead(false); err != nil {
		t.Fatal(err)
	}
	purged, _ := s.Stats()
	if purged.Pending != 1 || purged.Dead != 0 || purged.Bytes >= stats.Bytes {
		t.Fatal("purge changed pending records", purged)
	}
}

func TestConsumerRetryOrderingAndPoisonIsolation(t *testing.T) {
	s := openTest(t, filepath.Join(t.TempDir(), "queue.db"), testLimits)
	defer s.Close()
	var mu sync.Mutex
	var persisted []string
	var attempts atomic.Int32
	poison := errors.New("invalid input")
	c, err := NewConsumer(s, 4, func(_ context.Context, r Record) error {
		body := string(r.Payload)
		if body == "first" && attempts.Add(1) < 3 {
			return errors.New("DB offline")
		}
		if body == "poison" {
			return poison
		}
		mu.Lock()
		persisted = append(persisted, body)
		mu.Unlock()
		return nil
	}, func(err error) bool { return errors.Is(err, poison) }, zerolog.Nop())
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{"first", "poison", "last"} {
		if err := c.HandleIncomingMessage("chat/same", []byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Run(ctx); close(done) }()
	eventually(t, func() bool { stats, _ := s.Stats(); return stats.Pending == 0 })
	cancel()
	<-done
	mu.Lock()
	defer mu.Unlock()
	if fmt.Sprint(persisted) != "[first last]" || c.Retries.Load() != 2 {
		t.Fatal("retry order lost", persisted, c.Retries.Load())
	}
	stats, _ := s.Stats()
	if stats.Dead != 1 {
		t.Fatal("poison discarded")
	}
}

func TestWorkerCountBoundsParallelismAndCanChangeAfterRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	s := openTest(t, path, testLimits)
	for i := 0; i < 128; i++ {
		if _, err := s.Append(fmt.Sprintf("chat/%d", i), []byte("payload")); err != nil {
			t.Fatal(err)
		}
	}
	_ = s.Close()
	s = openTest(t, path, testLimits)
	defer s.Close()
	var active, max atomic.Int32
	c, err := NewConsumer(s, 3, func(ctx context.Context, _ Record) error {
		n := active.Add(1)
		defer active.Add(-1)
		for old := max.Load(); n > old; old = max.Load() {
			if max.CompareAndSwap(old, n) {
				break
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Millisecond):
			return nil
		}
	}, func(error) bool { return false }, zerolog.Nop())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Run(ctx); close(done) }()
	eventually(t, func() bool { stats, _ := s.Stats(); return stats.Pending == 0 })
	cancel()
	<-done
	if max.Load() < 2 || max.Load() > 3 || c.Processed.Load() != 128 {
		t.Fatal("pool did not bound/recover backlog", max.Load(), c.Processed.Load())
	}
}

func TestByteAndPayloadLimits(t *testing.T) {
	limits := testLimits
	limits.MaxBytes = 10
	s := openTest(t, filepath.Join(t.TempDir(), "q"), limits)
	defer s.Close()
	if _, err := s.Append("chat/x", []byte("one")); !errors.Is(err, ErrFull) {
		t.Fatal(err)
	}
	if _, err := s.Append("chat/x", make([]byte, limits.MaxPayloadBytes+1)); !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatal(err)
	}
	stats, _ := s.Stats()
	if stats.Pending != 0 || stats.Bytes != 0 {
		t.Fatal("failed append changed accounting")
	}
}
