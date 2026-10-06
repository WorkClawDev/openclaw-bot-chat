package ingest

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
)

type Handler func(context.Context, Record) error
type Consumer struct {
	spool        *Spool
	handle       Handler
	permanent    func(error) bool
	log          zerolog.Logger
	wake         []chan struct{}
	Processed    atomic.Uint64
	Retries      atomic.Uint64
	IntakeFailed atomic.Bool
}

func NewConsumer(spool *Spool, workers int, handle Handler, permanent func(error) bool, log zerolog.Logger) (*Consumer, error) {
	if workers < 1 || workers > partitions || handle == nil || permanent == nil {
		return nil, errors.New("ingest requires 1..64 workers and handlers")
	}
	c := &Consumer{spool: spool, handle: handle, permanent: permanent, log: log, wake: make([]chan struct{}, workers)}
	for i := range c.wake {
		c.wake[i] = make(chan struct{}, 1)
	}
	return c, nil
}
func (c *Consumer) HandleIncomingMessage(topic string, payload []byte) error {
	p, err := c.spool.Append(topic, payload)
	c.IntakeFailed.Store(err != nil)
	if err == nil {
		select {
		case c.wake[p%len(c.wake)] <- struct{}{}:
		default:
		}
	}
	return err
}

// Run uses a fixed worker pool, serializing each durable partition. A failing
// partition backs off without blocking unrelated partitions owned by the worker.
func (c *Consumer) Run(ctx context.Context) {
	var wg sync.WaitGroup
	for i := range c.wake {
		wg.Add(1)
		go func(worker int) { defer wg.Done(); c.runWorker(ctx, worker) }(i)
	}
	wg.Wait()
}
func (c *Consumer) runWorker(ctx context.Context, worker int) {
	next := make([]time.Time, partitions)
	backoff := make([]time.Duration, partitions)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for ctx.Err() == nil {
		progress := false
		for p := worker; p < partitions && ctx.Err() == nil; p += len(c.wake) {
			if time.Now().Before(next[p]) {
				continue
			}
			key, record, err := c.spool.Peek(p)
			if err == nil && key == nil {
				continue
			}
			if err == nil {
				attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
				err = c.handle(attempt, record)
				cancel()
				if err == nil || c.permanent(err) {
					if err != nil {
						c.log.Warn().Err(err).Str("delivery_id", record.ID.String()).Msg("message moved to durable dead-letter queue")
					}
					err = c.spool.Finish(p, key, err != nil)
					if err == nil {
						c.Processed.Add(1)
						progress = true
						backoff[p] = 0
						continue
					}
				}
			}
			if ctx.Err() != nil {
				return
			}
			c.Retries.Add(1)
			if backoff[p] == 0 {
				backoff[p] = 100 * time.Millisecond
			} else {
				backoff[p] *= 2
			}
			if backoff[p] > 5*time.Second {
				backoff[p] = 5 * time.Second
			}
			next[p] = time.Now().Add(backoff[p])
			c.log.Warn().Err(err).Int("partition", p).Dur("retry_in", backoff[p]).Msg("message persistence will retry")
		}
		if progress {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-c.wake[worker]:
		case <-ticker.C:
		}
	}
}
