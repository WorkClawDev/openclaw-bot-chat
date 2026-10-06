package service

import (
	"context"
	"crypto/subtle"
	"errors"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

var ErrPhoneCodeNotFound = errors.New("phone verification code not found")

type PhoneCodeStore interface {
	SetNX(ctx context.Context, key string, value string, ttl time.Duration) (bool, error)
	Set(ctx context.Context, key string, value string, ttl time.Duration) error
	Get(ctx context.Context, key string) (string, error)
	Delete(ctx context.Context, keys ...string) error
	IncrWithTTL(ctx context.Context, key string, ttl time.Duration) (int64, error)
	// VerifyAndConsume counts an attempt and consumes a matching live code atomically.
	VerifyAndConsume(ctx context.Context, codeKey, attemptKey, expectedHash string, maxAttempts int, ttl time.Duration) (bool, error)
}

type RedisPhoneCodeStore struct {
	client *redis.Client
}

func NewRedisPhoneCodeStore(client *redis.Client) *RedisPhoneCodeStore {
	return &RedisPhoneCodeStore{client: client}
}

func (s *RedisPhoneCodeStore) SetNX(ctx context.Context, key string, value string, ttl time.Duration) (bool, error) {
	return s.client.SetNX(ctx, key, value, ttl).Result()
}

func (s *RedisPhoneCodeStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	return s.client.Set(ctx, key, value, ttl).Err()
}

func (s *RedisPhoneCodeStore) Get(ctx context.Context, key string) (string, error) {
	value, err := s.client.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", ErrPhoneCodeNotFound
	}
	return value, err
}

func (s *RedisPhoneCodeStore) Delete(ctx context.Context, keys ...string) error {
	if len(keys) == 0 {
		return nil
	}
	return s.client.Del(ctx, keys...).Err()
}

// Compare HMAC digests, never plaintext codes. All reads, the attempt limit and
// consumption run in one Redis operation so concurrent logins cannot both win.
var verifyPhoneCodeScript = redis.NewScript(`
local stored = redis.call('GET', KEYS[1])
if not stored then return 0 end
local attempts = redis.call('INCR', KEYS[2])
if attempts == 1 then redis.call('PEXPIRE', KEYS[2], ARGV[3]) end
if attempts > tonumber(ARGV[2]) then
    redis.call('DEL', KEYS[1], KEYS[2])
    return 0
end
local expected = ARGV[1]
if string.len(stored) ~= string.len(expected) then return 0 end
local difference = 0
for i = 1, string.len(expected) do
    difference = bit.bor(difference, bit.bxor(string.byte(stored, i), string.byte(expected, i)))
end
if difference ~= 0 then return 0 end
redis.call('DEL', KEYS[1], KEYS[2])
return 1
`)

func (s *RedisPhoneCodeStore) VerifyAndConsume(ctx context.Context, codeKey, attemptKey, expectedHash string, maxAttempts int, ttl time.Duration) (bool, error) {
	result, err := verifyPhoneCodeScript.Run(ctx, s.client, []string{codeKey, attemptKey}, expectedHash, maxAttempts, ttl.Milliseconds()).Int()
	return result == 1, err
}

func (s *RedisPhoneCodeStore) IncrWithTTL(ctx context.Context, key string, ttl time.Duration) (int64, error) {
	value, err := s.client.Incr(ctx, key).Result()
	if err != nil {
		return 0, err
	}
	if value == 1 {
		if err := s.client.Expire(ctx, key, ttl).Err(); err != nil {
			return 0, err
		}
	}
	return value, nil
}

type MemoryPhoneCodeStore struct {
	mu      sync.Mutex
	entries map[string]memoryPhoneCodeEntry
}

type memoryPhoneCodeEntry struct {
	value     string
	expiresAt time.Time
}

func NewMemoryPhoneCodeStore() *MemoryPhoneCodeStore {
	return &MemoryPhoneCodeStore{entries: map[string]memoryPhoneCodeEntry{}}
}

func (s *MemoryPhoneCodeStore) SetNX(ctx context.Context, key string, value string, ttl time.Duration) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(time.Now())
	if _, exists := s.entries[key]; exists {
		return false, nil
	}
	s.entries[key] = memoryPhoneCodeEntry{value: value, expiresAt: time.Now().Add(ttl)}
	return true, nil
}

func (s *MemoryPhoneCodeStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.entries[key] = memoryPhoneCodeEntry{value: value, expiresAt: time.Now().Add(ttl)}
	return nil
}

func (s *MemoryPhoneCodeStore) Get(ctx context.Context, key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(time.Now())
	entry, exists := s.entries[key]
	if !exists {
		return "", ErrPhoneCodeNotFound
	}
	return entry.value, nil
}

func (s *MemoryPhoneCodeStore) Delete(ctx context.Context, keys ...string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, key := range keys {
		delete(s.entries, key)
	}
	return nil
}

func (s *MemoryPhoneCodeStore) VerifyAndConsume(ctx context.Context, codeKey, attemptKey, expectedHash string, maxAttempts int, ttl time.Duration) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	now := time.Now()
	s.pruneLocked(now)
	code, exists := s.entries[codeKey]
	if !exists {
		return false, nil
	}
	attempt, exists := s.entries[attemptKey]
	count := int64(0)
	if exists {
		var err error
		count, err = strconv.ParseInt(attempt.value, 10, 64)
		if err != nil {
			return false, err
		}
	} else {
		attempt.expiresAt = now.Add(ttl)
	}
	count++
	attempt.value = strconv.FormatInt(count, 10)
	s.entries[attemptKey] = attempt
	if count > int64(maxAttempts) {
		delete(s.entries, codeKey)
		delete(s.entries, attemptKey)
		return false, nil
	}
	if subtle.ConstantTimeCompare([]byte(code.value), []byte(expectedHash)) != 1 {
		return false, nil
	}
	delete(s.entries, codeKey)
	delete(s.entries, attemptKey)
	return true, nil
}

func (s *MemoryPhoneCodeStore) IncrWithTTL(ctx context.Context, key string, ttl time.Duration) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(time.Now())
	entry, exists := s.entries[key]
	var value int64 = 1
	if exists {
		parsed, _ := strconv.ParseInt(entry.value, 10, 64)
		value = parsed + 1
	}
	s.entries[key] = memoryPhoneCodeEntry{value: strconv.FormatInt(value, 10), expiresAt: time.Now().Add(ttl)}
	return value, nil
}

func (s *MemoryPhoneCodeStore) pruneLocked(now time.Time) {
	for key, entry := range s.entries {
		if !entry.expiresAt.IsZero() && now.After(entry.expiresAt) {
			delete(s.entries, key)
		}
	}
}
