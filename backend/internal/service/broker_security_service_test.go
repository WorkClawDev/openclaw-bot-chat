package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"strings"
	"testing"
	"time"
)

type brokerFixtureStore struct {
	values map[string][]byte
	broken bool
}

func (s *brokerFixtureStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	if s.broken {
		return errors.New("offline")
	}
	s.values[key] = value
	return nil
}
func (s *brokerFixtureStore) Get(ctx context.Context, key string) ([]byte, error) {
	if s.broken {
		return nil, errors.New("offline")
	}
	return s.values[key], nil
}
func brokerFixture() (*BrokerSecurityService, *brokerFixtureStore) {
	store := &brokerFixtureStore{values: map[string][]byte{}}
	s := &BrokerSecurityService{store: store, settings: config.BrokerSecurityConfig{CallbackToken: strings.Repeat("c", 40), SessionTTLSeconds: 300}, server: config.MQTTConfig{Username: "server", ClientID: "server-id", Password: strings.Repeat("p", 40)}, validate: func(context.Context, *BrokerSession) (bool, error) { return true, nil }, topicAllowed: func(context.Context, *BrokerSession, string) (bool, error) { return true, nil }}
	return s, store
}
func TestBrokerCredentialsBoundScopedAndRevoked(t *testing.T) {
	s, store := brokerFixture()
	ctx := context.Background()
	bot, owner := uuid.New(), uuid.New()
	topic := "chat/dm/user/" + owner.String() + "/bot/" + bot.String()
	name, password, expiry, err := s.Mint(ctx, BrokerSession{ClientID: "client", ActorType: "bot", ActorID: bot, OwnerID: owner, Subscribe: []string{topic}, Publish: []string{topic}})
	if err != nil {
		t.Fatal(err)
	}
	if password == s.server.Password || strings.Contains(string(store.values["personal-agent:broker:"+name]), password) {
		t.Fatal("raw/shared secret persisted")
	}
	if ok, e := s.Authenticate(ctx, name, password, "client"); !ok || e != expiry {
		t.Fatal("valid authentication failed")
	}
	for _, pair := range [][2]string{{"wrong", "client"}, {password, "other"}} {
		if ok, _ := s.Authenticate(ctx, name, pair[0], pair[1]); ok {
			t.Fatal("unbound credential accepted")
		}
	}
	if !s.Authorize(ctx, name, "client", "publish", topic) || !s.Authorize(ctx, name, "client", "subscribe", topic) {
		t.Fatal("scoped action denied")
	}
	for _, bad := range []string{"chat/#", "chat/dm/user/+/bot/" + bot.String(), "agent/user/other/events", "chat/dm/user/other/bot/" + bot.String()} {
		if s.Authorize(ctx, name, "client", "subscribe", bad) || s.Authorize(ctx, name, "client", "publish", bad) {
			t.Fatal("scope enlarged", bad)
		}
	}
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return false, nil }
	if ok, _ := s.Authenticate(ctx, name, password, "client"); ok {
		t.Fatal("revoked accepted")
	}
	if s.Authorize(ctx, name, "client", "publish", topic) {
		t.Fatal("revoked publication allowed")
	}
}
func TestBrokerExpiryStoreFailureAndCallbackFailClosed(t *testing.T) {
	s, store := brokerFixture()
	ctx := context.Background()
	owner := uuid.New()
	name, password, _, err := s.Mint(ctx, BrokerSession{ClientID: "client", ActorType: "user", ActorID: owner, OwnerID: owner})
	if err != nil {
		t.Fatal(err)
	}
	var row BrokerSession
	json.Unmarshal(store.values["personal-agent:broker:"+name], &row)
	row.ExpiresAt = time.Now().Unix() - 1
	store.values["personal-agent:broker:"+name], _ = json.Marshal(row)
	if ok, _ := s.Authenticate(ctx, name, password, "client"); ok {
		t.Fatal("expired accepted")
	}
	store.broken = true
	if ok, _ := s.Authenticate(ctx, name, password, "client"); ok {
		t.Fatal("offline store accepted")
	}
	if _, _, _, err = s.Mint(ctx, BrokerSession{ClientID: "x", ActorType: "user", ActorID: owner, OwnerID: owner}); err == nil {
		t.Fatal("offline mint succeeded")
	}
	if s.ValidCallback("") || s.ValidCallback("wrong") || !s.ValidCallback(strings.Repeat("c", 40)) {
		t.Fatal("callback secret guard broken")
	}
}
func TestBrokerFiltersCannotEnlargeIssuedScopes(t *testing.T) {
	for _, tc := range []struct {
		a, r string
		ok   bool
	}{{"chat/dm/user/+/bot/b", "chat/dm/user/u/bot/b", true}, {"chat/dm/user/+/bot/b", "chat/dm/user/+/bot/b", true}, {"chat/dm/user/+/bot/b", "chat/dm/#", false}, {"chat/dm/user/u/bot/b", "chat/dm/user/+/bot/b", false}, {"chat/#", "agent/user/u/events", false}, {"chat/#", "chat/x", true}} {
		if brokerFilterCovers(tc.a, tc.r) != tc.ok {
			t.Errorf("%s covers %s", tc.a, tc.r)
		}
	}
}
func TestBrokerServerIdentityHasNoClientCredentialShortcut(t *testing.T) {
	s, _ := brokerFixture()
	ctx := context.Background()
	if ok, _ := s.Authenticate(ctx, "server", s.server.Password, "other-id"); ok {
		t.Fatal("server client binding lost")
	}
	if !s.Authorize(ctx, "server", "server-id", "subscribe", "chat/#") || s.Authorize(ctx, "server", "server-id", "subscribe", "#") {
		t.Fatal("server scope broken")
	}
}

func TestBrokerPublishIdentityCannotImpersonateAnotherActor(t *testing.T) {
	s, _ := brokerFixture()
	s.settings.RequireMessageIdentity = true
	ctx := context.Background()
	actor := uuid.New()
	name, _, _, err := s.Mint(ctx, BrokerSession{ClientID: "client", ActorType: "user", ActorID: actor, OwnerID: actor})
	if err != nil {
		t.Fatal(err)
	}
	topic := "chat/group/" + uuid.NewString()
	message := &BrokerMessageIdentity{From: &MessagePeerPayload{Type: "user", ID: actor.String()}, ConversationID: topic}
	if !s.AuthorizeMessage(ctx, name, "client", topic, message) {
		t.Fatal("own identity denied")
	}
	if s.AuthorizeMessage(ctx, name, "client", topic, nil) {
		t.Fatal("identity missing")
	}
	message.From.ID = uuid.NewString()
	if s.AuthorizeMessage(ctx, name, "client", topic, message) {
		t.Fatal("forged actor accepted")
	}
	message.From.ID = actor.String()
	message.From.Type = "bot"
	if s.AuthorizeMessage(ctx, name, "client", topic, message) {
		t.Fatal("forged actor type accepted")
	}
	message.From.Type = "user"
	message.SenderID = uuid.NewString()
	if s.AuthorizeMessage(ctx, name, "client", topic, message) {
		t.Fatal("contradicting sender fields accepted")
	}
	message.SenderID = ""
	message.ConversationID = "chat/group/other"
	if s.AuthorizeMessage(ctx, name, "client", topic, message) {
		t.Fatal("contradicting conversation accepted")
	}
}

func TestBrokerOpaquePayloadIsInterpretedOnlyByApplication(t *testing.T) {
	s, _ := brokerFixture()
	s.settings.RequireMessageIdentity = true
	ctx := context.Background()
	actor := uuid.New()
	name, _, _, err := s.Mint(ctx, BrokerSession{ClientID: "client", ActorType: "user", ActorID: actor, OwnerID: actor})
	if err != nil {
		t.Fatal(err)
	}
	topic := "chat/group/" + uuid.NewString()
	body := func(id, destination string) string {
		raw, _ := json.Marshal(map[string]any{
			"from":            map[string]string{"type": "user", "id": id},
			"conversation_id": destination,
			"content":         strings.Repeat("non-identity content ", 1000),
		})
		return base64.StdEncoding.EncodeToString(raw)
	}
	valid := body(actor.String(), topic)
	for _, tc := range []struct {
		name, encoding, data string
		allowed              bool
	}{
		{"valid large message", "base64", valid, true},
		{"forged sender", "base64", body(uuid.NewString(), topic), false},
		{"forged conversation", "base64", body(actor.String(), "chat/group/other"), false},
		{"wrong encoding", "utf8", valid, false},
		{"malformed base64", "base64", "%%%", false},
		{"binary chat payload", "base64", base64.StdEncoding.EncodeToString([]byte{0, 255}), false},
		{"null identity", "base64", base64.StdEncoding.EncodeToString([]byte("null")), false},
		{"array identity", "base64", base64.StdEncoding.EncodeToString([]byte("[]")), false},
		{"missing identity", "base64", base64.StdEncoding.EncodeToString([]byte("{}")), false},
		{"oversized payload", "base64", base64.StdEncoding.EncodeToString(make([]byte, MaxBrokerPayloadBytes+1)), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := s.AuthorizePublish(ctx, name, "client", topic, tc.encoding, &tc.data); got != tc.allowed {
				t.Fatalf("allowed=%v, want %v", got, tc.allowed)
			}
		})
	}
	if s.AuthorizePublish(ctx, name, "client", topic, "", nil) {
		t.Fatal("strict mode accepted callback without actual publish payload")
	}
	// The compatibility setting is explicit; MQTT topic authorization still runs
	// separately before this method is called.
	s.settings.RequireMessageIdentity = false
	if !s.AuthorizePublish(ctx, name, "client", topic, "", nil) {
		t.Fatal("explicit topic-only compatibility mode failed")
	}
}
