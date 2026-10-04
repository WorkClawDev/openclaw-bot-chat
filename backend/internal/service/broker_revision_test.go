package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

type revisionFixture struct {
	value     string
	broken    bool
	rotations int
}

func (s *revisionFixture) Current(context.Context) (string, error) {
	if s.broken {
		return "", errors.New("offline")
	}
	return s.value, nil
}
func (s *revisionFixture) Rotate(context.Context) error {
	if s.broken {
		return errors.New("offline")
	}
	s.value = uuid.NewString()
	s.rotations++
	return nil
}

func TestBrokerRevisionRecoversFailedInvalidation(t *testing.T) {
	store := &revisionFixture{value: "original", broken: true}
	r := &BrokerRevision{Store: store}
	ctx := context.Background()
	if r.Invalidate(ctx) == nil {
		t.Fatal("missed outage")
	}
	if _, err := r.Current(ctx); err == nil {
		t.Fatal("issued revision during outage")
	}
	store.broken = false
	value, err := r.Current(ctx)
	if err != nil || value == "original" || value == "" || store.rotations != 1 {
		t.Fatal("failed invalidation was not retried")
	}
	if next, _ := r.Current(ctx); next != value || store.rotations != 1 {
		t.Fatal("ordinary reads rotate revisions")
	}
}

func TestBrokerDecisionsDistinguishRevocationAndDependencyFailure(t *testing.T) {
	s, store := brokerFixture()
	ctx := context.Background()
	owner := uuid.New()
	name, password, _, err := s.Mint(ctx, BrokerSession{ClientID: "c", ActorType: "user", ActorID: owner, OwnerID: owner, Publish: []string{"events/one"}})
	if err != nil {
		t.Fatal(err)
	}
	store.broken = true
	if allowed, err := s.AuthorizeDecision(ctx, name, "c", "publish", "events/one"); allowed || err == nil {
		t.Fatal("Redis outage treated as explicit denial")
	}
	if allowed, _, err := s.AuthenticateDecision(ctx, name, password, "c"); allowed || err == nil {
		t.Fatal("Redis outage authentication")
	}
	store.broken = false
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return false, errors.New("DB offline") }
	if allowed, err := s.AuthorizeDecision(ctx, name, "c", "publish", "events/one"); allowed || err == nil {
		t.Fatal("DB outage treated as explicit denial")
	}
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return false, nil }
	if allowed, err := s.AuthorizeDecision(ctx, name, "c", "publish", "events/one"); allowed || err != nil {
		t.Fatal("revocation treated as outage")
	}
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return true, nil }
	s.topicAllowed = func(context.Context, *BrokerSession, string) (bool, error) {
		return false, errors.New("membership DB offline")
	}
	if allowed, err := s.AuthorizeDecision(ctx, name, "c", "publish", "events/one"); allowed || err == nil {
		t.Fatal("membership lookup outage lost")
	}
}
