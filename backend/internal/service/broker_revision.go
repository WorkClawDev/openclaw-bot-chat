package service

import (
	"context"
	"sync/atomic"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// BrokerRevisionStore is owned by the application. Brokers only see an opaque
// revision through HTTP; they never connect to this Redis instance.
type BrokerRevisionStore interface {
	Current(context.Context) (string, error)
	Rotate(context.Context) error
}

type RedisBrokerRevisionStore struct{ Client *redis.Client }

const brokerRevisionKey = "personal-agent:broker-policy-revision"

func (s RedisBrokerRevisionStore) Current(ctx context.Context) (string, error) {
	value, err := s.Client.Get(ctx, brokerRevisionKey).Result()
	if err != redis.Nil {
		return value, err
	}
	// Random revisions prevent old grants surviving a Redis reset/restore.
	if err = s.Client.SetNX(ctx, brokerRevisionKey, uuid.NewString(), 0).Err(); err != nil {
		return "", err
	}
	return s.Client.Get(ctx, brokerRevisionKey).Result()
}

func (s RedisBrokerRevisionStore) Rotate(ctx context.Context) error {
	return s.Client.Set(ctx, brokerRevisionKey, uuid.NewString(), 0).Err()
}

type BrokerRevision struct {
	Store BrokerRevisionStore
	dirty atomic.Bool
}

func (r *BrokerRevision) Current(ctx context.Context) (string, error) {
	// Retry a failed notification when Redis recovers. Periodic authorization
	// refresh also covers direct DB writes or a process crash before notification.
	if r.dirty.CompareAndSwap(true, false) {
		if err := r.Invalidate(ctx); err != nil {
			return "", err
		}
	}
	return r.Store.Current(ctx)
}

func (r *BrokerRevision) Invalidate(ctx context.Context) error {
	if err := r.Store.Rotate(ctx); err != nil {
		r.dirty.Store(true)
		return err
	}
	return nil
}
