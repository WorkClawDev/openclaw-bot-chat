// Package ingest implements the application's bounded, durable message consumer.
// It has no dependency on the HTTP API, Redis, or broker internals.
package ingest

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"
	bolt "go.etcd.io/bbolt"
)

const partitions = 64 // Stable on disk, independent of the configured worker count.

var (
	ErrFull            = errors.New("message spool capacity exhausted")
	ErrPayloadTooLarge = errors.New("message exceeds intake payload limit")
	metaBucket         = []byte("metadata")
	deadBucket         = []byte("dead")
)

type Limits struct {
	MaxBytes, MaxMessages int64
	MaxPayloadBytes       int
}
type Record struct {
	ID         uuid.UUID `json:"id"`
	Topic      string    `json:"topic"`
	Payload    []byte    `json:"payload"`
	ReceivedAt time.Time `json:"received_at"`
}
type Stats struct {
	Pending int64 `json:"pending"`
	Dead    int64 `json:"dead"`
	Bytes   int64 `json:"bytes"`
}
type Spool struct {
	db     *bolt.DB
	limits Limits
}

func Open(path string, limits Limits) (*Spool, error) {
	if path == "" || limits.MaxBytes <= 0 || limits.MaxMessages <= 0 || limits.MaxPayloadBytes <= 0 {
		return nil, errors.New("positive spool limits and a path are required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := bolt.Open(path, 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	s := &Spool{db: db, limits: limits}
	err = db.Update(func(tx *bolt.Tx) error {
		meta, err := tx.CreateBucketIfNotExists(metaBucket)
		if err != nil {
			return err
		}
		if v := meta.Get([]byte("version")); v != nil && string(v) != "1" {
			return errors.New("unsupported spool version")
		}
		if err := meta.Put([]byte("version"), []byte("1")); err != nil {
			return err
		}
		if _, err := tx.CreateBucketIfNotExists(deadBucket); err != nil {
			return err
		}
		for p := 0; p < partitions; p++ {
			if _, err := tx.CreateBucketIfNotExists(bucket(p)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}
func (s *Spool) Close() error { return s.db.Close() }
func bucket(p int) []byte     { return []byte(fmt.Sprintf("pending-%02d", p)) }
func partition(topic string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(topic))
	return int(h.Sum32() % partitions)
}
func number(b *bolt.Bucket, key string) int64 {
	v := b.Get([]byte(key))
	if len(v) != 8 {
		return 0
	}
	return int64(binary.BigEndian.Uint64(v))
}
func change(b *bolt.Bucket, key string, delta int64) error {
	var v [8]byte
	binary.BigEndian.PutUint64(v[:], uint64(number(b, key)+delta))
	return b.Put([]byte(key), v[:])
}

// Append returns only after bbolt's synchronous commit. MQTT PUBACK must follow
// this return, never precede it. The byte budget includes dead letters.
func (s *Spool) Append(topic string, payload []byte) (int, error) {
	if len(payload) > s.limits.MaxPayloadBytes {
		return 0, ErrPayloadTooLarge
	}
	p := partition(topic)
	record := Record{ID: uuid.New(), Topic: topic, Payload: payload, ReceivedAt: time.Now().UTC()}
	raw, err := json.Marshal(record)
	if err != nil {
		return 0, err
	}
	err = s.db.Update(func(tx *bolt.Tx) error {
		meta := tx.Bucket(metaBucket)
		if number(meta, "bytes")+int64(len(raw)) > s.limits.MaxBytes || number(meta, "pending")+number(meta, "dead") >= s.limits.MaxMessages {
			return ErrFull
		}
		seq, err := meta.NextSequence()
		if err != nil {
			return err
		}
		var key [8]byte
		binary.BigEndian.PutUint64(key[:], seq)
		if err := tx.Bucket(bucket(p)).Put(key[:], raw); err != nil {
			return err
		}
		if err := change(meta, "pending", 1); err != nil {
			return err
		}
		return change(meta, "bytes", int64(len(raw)))
	})
	return p, err
}
func (s *Spool) Peek(p int) (key []byte, record Record, err error) {
	err = s.db.View(func(tx *bolt.Tx) error {
		k, v := tx.Bucket(bucket(p)).Cursor().First()
		if k == nil {
			return nil
		}
		key = append([]byte(nil), k...)
		return json.Unmarshal(v, &record)
	})
	return
}

// Finish atomically removes a committed record or preserves malformed input in
// the dead-letter bucket. Dead letters keep their capacity until an operator
// exports/replays or removes them; they are never silently discarded.
func (s *Spool) Finish(p int, key []byte, dead bool) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket(p))
		raw := b.Get(key)
		if raw == nil {
			return nil
		}
		meta := tx.Bucket(metaBucket)
		if dead {
			if err := tx.Bucket(deadBucket).Put(key, raw); err != nil {
				return err
			}
			if err := change(meta, "dead", 1); err != nil {
				return err
			}
		} else if err := change(meta, "bytes", -int64(len(raw))); err != nil {
			return err
		}
		if err := change(meta, "pending", -1); err != nil {
			return err
		}
		return b.Delete(key)
	})
}
func (s *Spool) Stats() (stats Stats, err error) {
	err = s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(metaBucket)
		stats = Stats{Pending: number(b, "pending"), Dead: number(b, "dead"), Bytes: number(b, "bytes")}
		return nil
	})
	return
}
func (s *Spool) HasCapacity(stats Stats) bool {
	return stats.Pending+stats.Dead < s.limits.MaxMessages && stats.Bytes < s.limits.MaxBytes
}

// ExportDead emits JSONL to an operator-owned file, never a public endpoint.
func (s *Spool) ExportDead(w io.Writer) error {
	return s.db.View(func(tx *bolt.Tx) error {
		encoder := json.NewEncoder(w)
		return tx.Bucket(deadBucket).ForEach(func(_, raw []byte) error {
			var record Record
			if err := json.Unmarshal(raw, &record); err != nil {
				return err
			}
			return encoder.Encode(record)
		})
	})
}

// ResolveDead requeues records after a validator fix, or removes records that
// an operator has explicitly exported. Only a stopped consumer can open its file.
func (s *Spool) ResolveDead(replay bool) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		dead := tx.Bucket(deadBucket)
		meta := tx.Bucket(metaBucket)
		for {
			key, raw := dead.Cursor().First()
			if key == nil {
				return nil
			}
			if replay {
				var record Record
				if err := json.Unmarshal(raw, &record); err != nil {
					return err
				}
				if err := tx.Bucket(bucket(partition(record.Topic))).Put(key, raw); err != nil {
					return err
				}
				if err := change(meta, "pending", 1); err != nil {
					return err
				}
			} else if err := change(meta, "bytes", -int64(len(raw))); err != nil {
				return err
			}
			if err := change(meta, "dead", -1); err != nil {
				return err
			}
			if err := dead.Delete(key); err != nil {
				return err
			}
		}
	})
}
