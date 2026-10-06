package service

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

func TestMemoryPhoneCodeAtomicVerification(t *testing.T) {
	testPhoneCodeAtomicVerification(t, NewMemoryPhoneCodeStore())
}

func TestRedisPhoneCodeAtomicVerification(t *testing.T) {
	address := os.Getenv("TEST_PHONE_REDIS_ADDR")
	if address == "" {
		t.Skip("set TEST_PHONE_REDIS_ADDR to an isolated local Redis for integration acceptance")
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil || (host != "127.0.0.1" && host != "::1") {
		t.Fatal("integration Redis must use a loopback address")
	}
	client := redis.NewClient(&redis.Options{Addr: address})
	t.Cleanup(func() { _ = client.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatal(err)
	}
	testPhoneCodeAtomicVerification(t, NewRedisPhoneCodeStore(client))
}

func testPhoneCodeAtomicVerification(t *testing.T, store PhoneCodeStore) {
	t.Helper()
	const expected = "71a602d543bf81f4d5b98efcdbbca681e1d7d70e2514641b247cbe85b4b7e182"
	const wrong = "f1a602d543bf81f4d5b98efcdbbca681e1d7d70e2514641b247cbe85b4b7e182"
	ctx := context.Background()
	keys := func(t *testing.T) (string, string) {
		t.Helper()
		prefix := "phoneauth:test:" + uuid.NewString()
		code, attempts := prefix+":code", prefix+":attempts"
		t.Cleanup(func() {
			if err := store.Delete(ctx, code, attempts); err != nil {
				t.Error(err)
			}
		})
		return code, attempts
	}
	put := func(t *testing.T, key, value string, ttl time.Duration) {
		t.Helper()
		if err := store.Set(ctx, key, value, ttl); err != nil {
			t.Fatal(err)
		}
	}
	verify := func(t *testing.T, code, attempts, value string, max int, want bool) {
		t.Helper()
		got, err := store.VerifyAndConsume(ctx, code, attempts, value, max, time.Minute)
		if err != nil || got != want {
			t.Fatalf("accepted=%v err=%v, want %v", got, err, want)
		}
	}
	missing := func(t *testing.T, key string) {
		t.Helper()
		if _, err := store.Get(ctx, key); !errors.Is(err, ErrPhoneCodeNotFound) {
			t.Fatalf("expected missing key, got %v", err)
		}
	}
	t.Run("wrong then correct and replay", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		verify(t, code, attempts, wrong, 5, false)
		if got, err := store.Get(ctx, attempts); err != nil || got != "1" {
			t.Fatalf("attempt count=%q err=%v", got, err)
		}
		verify(t, code, attempts, expected, 5, true)
		verify(t, code, attempts, expected, 5, false)
		missing(t, code)
		missing(t, attempts)
	})
	t.Run("attempt limit invalidates correct code", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		verify(t, code, attempts, wrong, 2, false)
		verify(t, code, attempts, wrong, 2, false)
		verify(t, code, attempts, expected, 2, false)
		missing(t, code)
		missing(t, attempts)
	})
	t.Run("last permitted attempt succeeds", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		verify(t, code, attempts, wrong, 2, false)
		verify(t, code, attempts, expected, 2, true)
	})
	t.Run("missing and expired code", func(t *testing.T) {
		code, attempts := keys(t)
		verify(t, code, attempts, expected, 5, false)
		missing(t, attempts)
		put(t, code, expected, 20*time.Millisecond)
		deadline := time.Now().Add(2 * time.Second)
		for {
			_, err := store.Get(ctx, code)
			if errors.Is(err, ErrPhoneCodeNotFound) {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
			if time.Now().After(deadline) {
				t.Fatal("code did not expire")
			}
			time.Sleep(5 * time.Millisecond)
		}
		verify(t, code, attempts, expected, 5, false)
		missing(t, attempts)
	})
	t.Run("old hash cannot consume replacement", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		put(t, code, wrong, time.Minute)
		verify(t, code, attempts, expected, 5, false)
		verify(t, code, attempts, wrong, 5, true)
	})
	t.Run("unrelated recipient remains usable", func(t *testing.T) {
		code, attempts := keys(t)
		other, otherAttempts := keys(t)
		put(t, code, expected, time.Minute)
		put(t, other, expected, time.Minute)
		verify(t, code, attempts, expected, 5, true)
		verify(t, other, otherAttempts, expected, 5, true)
	})
	t.Run("concurrent single winner", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		type result struct {
			accepted bool
			err      error
		}
		const workers = 32
		start := make(chan struct{})
		results := make(chan result, workers)
		runCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		for i := 0; i < workers; i++ {
			go func() {
				<-start
				ok, err := store.VerifyAndConsume(runCtx, code, attempts, expected, workers, time.Minute)
				results <- result{ok, err}
			}()
		}
		close(start)
		winners := 0
		for i := 0; i < workers; i++ {
			r := <-results
			if r.err != nil {
				t.Fatal(r.err)
			}
			if r.accepted {
				winners++
			}
		}
		if winners != 1 {
			t.Fatalf("winners=%d, want 1", winners)
		}
		missing(t, code)
		missing(t, attempts)
	})
	t.Run("malformed attempt state fails closed", func(t *testing.T) {
		code, attempts := keys(t)
		put(t, code, expected, time.Minute)
		put(t, attempts, "invalid", time.Minute)
		if ok, err := store.VerifyAndConsume(ctx, code, attempts, expected, 5, time.Minute); ok || err == nil {
			t.Fatalf("invalid state accepted=%v error=%v", ok, err)
		}
		if got, err := store.Get(ctx, code); err != nil || !strings.EqualFold(got, expected) {
			t.Fatal("failed verification consumed code")
		}
	})
}
