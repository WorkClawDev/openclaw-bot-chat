package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
	"strings"
	"time"
)

type BrokerSessionStore interface {
	Put(context.Context, string, []byte, time.Duration) error
	Get(context.Context, string) ([]byte, error)
}
type RedisBrokerSessionStore struct{ Client *redis.Client }

func (s RedisBrokerSessionStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	return s.Client.Set(ctx, key, value, ttl).Err()
}
func (s RedisBrokerSessionStore) Get(ctx context.Context, key string) ([]byte, error) {
	return s.Client.Get(ctx, key).Bytes()
}

type BrokerSession struct {
	Username     string    `json:"username"`
	ClientID     string    `json:"client_id"`
	PasswordHash string    `json:"password_hash"`
	ActorType    string    `json:"actor_type"`
	ActorID      uuid.UUID `json:"actor_id"`
	OwnerID      uuid.UUID `json:"owner_id"`
	KeyPrefix    string    `json:"key_prefix,omitempty"`
	Subscribe    []string  `json:"subscribe"`
	Publish      []string  `json:"publish"`
	ExpiresAt    int64     `json:"expires_at"`
}

type BrokerMessageIdentity struct {
	From           *MessagePeerPayload `json:"from"`
	SenderType     string              `json:"sender_type"`
	SenderID       string              `json:"sender_id"`
	ConversationID string              `json:"conversation_id"`
	Topic          string              `json:"topic"`
}

// MaxBrokerPayloadBytes matches the application's configured MQTT packet limit.
// The generic broker forwards opaque bytes; all message parsing belongs here.
const MaxBrokerPayloadBytes = 1024 * 1024

func (s *BrokerSecurityService) AuthorizePublish(ctx context.Context, username, clientID, topic, encoding string, payload *string) bool {
	if payload == nil {
		return encoding == "" && s.AuthorizeMessage(ctx, username, clientID, topic, nil)
	}
	if encoding != "base64" || len(*payload) > base64.StdEncoding.EncodedLen(MaxBrokerPayloadBytes) {
		return false
	}
	raw, err := base64.StdEncoding.Strict().DecodeString(*payload)
	if err != nil || len(raw) > MaxBrokerPayloadBytes {
		return false
	}
	if !strings.HasPrefix(topic, "chat/") {
		return true
	}
	var message *BrokerMessageIdentity
	if json.Unmarshal(raw, &message) != nil || message == nil {
		return false
	}
	return s.AuthorizeMessage(ctx, username, clientID, topic, message)
}

// Claimed identity comes from the actual publish packet forwarded by the broker.
// The frontend cannot impersonate another group member or Agent by changing JSON.
func (s *BrokerSecurityService) AuthorizeMessage(ctx context.Context, username, clientID, topic string, message *BrokerMessageIdentity) bool {
	if !strings.HasPrefix(topic, "chat/") {
		return true
	}
	if message == nil {
		return !s.settings.RequireMessageIdentity
	}
	if username == s.server.Username && clientID == s.server.ClientID {
		return true
	}
	row, ok := s.session(ctx, username, clientID)
	if !ok {
		return false
	}
	if (message.ConversationID != "" && message.ConversationID != topic) || (message.Topic != "" && message.Topic != topic) {
		return false
	}
	kind, id := message.SenderType, message.SenderID
	if message.From != nil {
		if (kind != "" && kind != message.From.Type) || (id != "" && id != message.From.ID) {
			return false
		}
		kind, id = message.From.Type, message.From.ID
	}
	return kind == row.ActorType && id == row.ActorID.String()
}

type BrokerSecurityService struct {
	store        BrokerSessionStore
	settings     config.BrokerSecurityConfig
	server       config.MQTTConfig
	validate     func(context.Context, *BrokerSession) bool
	topicAllowed func(context.Context, *BrokerSession, string) bool
}

func NewBrokerSecurityService(store BrokerSessionStore, settings config.BrokerSecurityConfig, server config.MQTTConfig, db *gorm.DB, messages *MessageService) *BrokerSecurityService {
	s := &BrokerSecurityService{store: store, settings: settings, server: server}
	s.validate = func(ctx context.Context, row *BrokerSession) bool {
		var count int64
		if db.WithContext(ctx).Model(&model.User{}).Where("id = ? AND status = ? AND is_deleted = false", row.OwnerID, model.UserStatusActive).Count(&count).Error != nil || count != 1 {
			return false
		}
		if row.ActorType == "bot" {
			if db.WithContext(ctx).Model(&model.Bot{}).Where("id = ? AND owner_id = ? AND status = ?", row.ActorID, row.OwnerID, model.BotStatusEnabled).Count(&count).Error != nil || count != 1 {
				return false
			}
			if db.WithContext(ctx).Model(&model.BotKey{}).Where("bot_id = ? AND key_prefix = ? AND is_active = ? AND (expires_at IS NULL OR expires_at > ?)", row.ActorID, row.KeyPrefix, true, time.Now().UTC()).Count(&count).Error != nil || count != 1 {
				return false
			}
		}
		return true
	}
	s.topicAllowed = func(ctx context.Context, row *BrokerSession, topic string) bool {
		if !strings.HasPrefix(topic, "chat/") {
			return true
		}
		if strings.ContainsAny(topic, "+#") {
			return true
		}
		if row.ActorType == "user" {
			return messages.CanUserAccessConversation(ctx, row.ActorID, topic) == nil
		}
		return messages.CanBotAccessConversation(ctx, row.ActorID, topic) == nil
	}
	return s
}
func (s *BrokerSecurityService) Configured() bool {
	return s != nil && s.store != nil && len(s.settings.CallbackToken) >= 32 && len(s.server.Password) >= 32 && s.server.Username != "" && s.server.ClientID != ""
}
func (s *BrokerSecurityService) ValidCallback(token string) bool {
	return s.Configured() && subtle.ConstantTimeCompare([]byte(token), []byte(s.settings.CallbackToken)) == 1
}
func hashBrokerPassword(password string) string {
	sum := sha256.Sum256([]byte(password))
	return hex.EncodeToString(sum[:])
}
func (s *BrokerSecurityService) Mint(ctx context.Context, scope BrokerSession) (string, string, int64, error) {
	if !s.Configured() || scope.ClientID == "" || scope.ActorID == uuid.Nil || scope.OwnerID == uuid.Nil || !s.validate(ctx, &scope) {
		return "", "", 0, errors.New("broker security unavailable")
	}
	if (scope.ActorType != "user" && scope.ActorType != "bot") || (scope.ActorType == "user" && scope.ActorID != scope.OwnerID) {
		return "", "", 0, errors.New("invalid broker actor")
	}
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", "", 0, err
	}
	password := base64.RawURLEncoding.EncodeToString(bytes)
	scope.Username = "pa-" + uuid.NewString()
	scope.PasswordHash = hashBrokerPassword(password)
	ttl := time.Duration(s.settings.SessionTTLSeconds) * time.Second
	if ttl < time.Minute || ttl > 5*time.Minute {
		ttl = 5 * time.Minute
	}
	scope.ExpiresAt = time.Now().Add(ttl).Unix()
	data, err := json.Marshal(scope)
	if err != nil {
		return "", "", 0, err
	}
	if err = s.store.Put(ctx, "personal-agent:broker:"+scope.Username, data, ttl); err != nil {
		return "", "", 0, err
	}
	return scope.Username, password, scope.ExpiresAt, nil
}
func (s *BrokerSecurityService) session(ctx context.Context, username, clientID string) (*BrokerSession, bool) {
	if !s.Configured() {
		return nil, false
	}
	data, err := s.store.Get(ctx, "personal-agent:broker:"+username)
	if err != nil {
		return nil, false
	}
	var row BrokerSession
	if json.Unmarshal(data, &row) != nil || row.Username != username || row.ClientID != clientID || row.ExpiresAt <= time.Now().Unix() || !s.validate(ctx, &row) {
		return nil, false
	}
	return &row, true
}
func (s *BrokerSecurityService) Authenticate(ctx context.Context, username, password, clientID string) (bool, int64) {
	if s.Configured() && username == s.server.Username && clientID == s.server.ClientID && subtle.ConstantTimeCompare([]byte(password), []byte(s.server.Password)) == 1 {
		return true, 0
	}
	row, ok := s.session(ctx, username, clientID)
	if !ok {
		return false, 0
	}
	return subtle.ConstantTimeCompare([]byte(hashBrokerPassword(password)), []byte(row.PasswordHash)) == 1, row.ExpiresAt
}
func (s *BrokerSecurityService) Authorize(ctx context.Context, username, clientID, action, topic string) bool {
	if !s.Configured() || (action != "publish" && action != "subscribe") || topic == "" {
		return false
	}
	if action == "publish" && strings.ContainsAny(topic, "+#") {
		return false
	}
	if username == s.server.Username && clientID == s.server.ClientID {
		if action == "subscribe" {
			return brokerFilterCovers("chat/#", topic)
		}
		return brokerFilterCovers("agent/user/+/events", topic) || brokerFilterCovers("chat/#", topic)
	}
	row, ok := s.session(ctx, username, clientID)
	if !ok {
		return false
	}
	allowed := row.Subscribe
	if action == "publish" {
		allowed = row.Publish
	}
	for _, filter := range allowed {
		if brokerFilterCovers(filter, topic) && s.topicAllowed(ctx, row, topic) {
			return true
		}
	}
	return false
}

// A requested subscription must be a subset of an issued filter. Exact user
// topics cannot be enlarged into + or #; a bot's own DM filters remain scoped.
func brokerFilterCovers(allowed, requested string) bool {
	a, r := strings.Split(allowed, "/"), strings.Split(requested, "/")
	for i, part := range a {
		if part == "#" {
			return i == len(a)-1
		}
		if i >= len(r) || r[i] == "#" {
			return false
		}
		if part != "+" && part != r[i] {
			return false
		}
	}
	return len(a) == len(r)
}
