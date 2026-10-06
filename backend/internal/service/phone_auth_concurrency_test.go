package service

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Force both old read/compare/delete calls to observe the same live code.
// An atomic verifier does not call Get and cannot enter this interleaving.
type phoneCodeReadBarrier struct {
	*MemoryPhoneCodeStore
	mu      sync.Mutex
	readers int
	ready   chan struct{}
}

func (s *phoneCodeReadBarrier) Get(ctx context.Context, key string) (string, error) {
	value, err := s.MemoryPhoneCodeStore.Get(ctx, key)
	if err != nil {
		return value, err
	}
	s.mu.Lock()
	s.readers++
	if s.readers == 2 {
		close(s.ready)
	}
	s.mu.Unlock()
	select {
	case <-s.ready:
		return value, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func TestPhoneCodeConcurrentRedemptionHasOneWinner(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const phone = "13800138000"
	if err := env.service.RequestCode(ctx, PhoneCodeRequest{Phone: phone, CaptchaToken: "pass"}, "127.0.0.1", "test"); err != nil {
		t.Fatal(err)
	}
	env.service.store = &phoneCodeReadBarrier{MemoryPhoneCodeStore: env.store, ready: make(chan struct{})}
	results := make(chan error, 2)
	start := make(chan struct{})
	for i := 0; i < 2; i++ {
		go func() {
			<-start
			results <- env.service.verifyCode(ctx, "login", "86", phone, "123456")
		}()
	}
	close(start)
	successes := 0
	for i := 0; i < 2; i++ {
		err := <-results
		if err == nil {
			successes++
		} else if !errors.Is(err, ErrInvalidPhoneCode) {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatalf("successful redemptions = %d, want exactly one", successes)
	}
}
