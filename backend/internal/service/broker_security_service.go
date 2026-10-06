package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/brokerrpc"
	pb "github.com/openclaw-bot-chat/backend/internal/brokerrpc/authzv1"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"gorm.io/gorm"
	"strings"
	"sync"
	"time"
)

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

// BrokerSecurityService publishes business permissions to the independent MQTTS
// authorization module. It is never called by the broker's message data path.
type BrokerSecurityService struct {
	settings     config.BrokerSecurityConfig
	server       config.MQTTConfig
	admin        pb.AdministrationClient
	connection   *grpc.ClientConn
	notify       chan struct{}
	reconcile    sync.Mutex
	validate     func(context.Context, *BrokerSession) (bool, error)
	topicAllowed func(context.Context, *BrokerSession, string) (bool, error)
}

func NewBrokerSecurityService(settings config.BrokerSecurityConfig, server config.MQTTConfig, db *gorm.DB, messages *MessageService) (*BrokerSecurityService, error) {
	if settings.Namespace == "" {
		settings.Namespace = "openclaw"
	}
	s := &BrokerSecurityService{settings: settings, server: server, notify: make(chan struct{}, 1)}
	s.validate = func(ctx context.Context, row *BrokerSession) (bool, error) {
		var count int64
		if err := db.WithContext(ctx).Model(&model.User{}).Where("id = ? AND status = ? AND is_deleted = false", row.OwnerID, model.UserStatusActive).Count(&count).Error; err != nil || count != 1 {
			return false, err
		}
		if row.ActorType == "bot" {
			if err := db.WithContext(ctx).Model(&model.Bot{}).Where("id = ? AND owner_id = ? AND status = ?", row.ActorID, row.OwnerID, model.BotStatusEnabled).Count(&count).Error; err != nil || count != 1 {
				return false, err
			}
			if err := db.WithContext(ctx).Model(&model.BotKey{}).Where("bot_id = ? AND key_prefix = ? AND is_active = ? AND (expires_at IS NULL OR expires_at > ?)", row.ActorID, row.KeyPrefix, true, time.Now().UTC()).Count(&count).Error; err != nil || count != 1 {
				return false, err
			}
		}
		return true, nil
	}
	s.topicAllowed = func(ctx context.Context, row *BrokerSession, topic string) (bool, error) {
		if !strings.HasPrefix(topic, "chat/") {
			return true, nil
		}
		if strings.ContainsAny(topic, "+#") {
			return true, nil
		}
		var err error
		if row.ActorType == "user" {
			err = messages.CanUserAccessConversation(ctx, row.ActorID, topic)
		} else {
			err = messages.CanBotAccessConversation(ctx, row.ActorID, topic)
		}
		if errors.Is(err, ErrConversationAccessDenied) || errors.Is(err, ErrInvalidMessageRoute) || errors.Is(err, gorm.ErrRecordNotFound) {
			return false, nil
		}
		return err == nil, err
	}
	if settings.Address == "" {
		return s, nil
	}
	conn, err := brokerrpc.Dial(settings)
	if err != nil {
		return nil, err
	}
	s.connection = conn
	s.admin = pb.NewAdministrationClient(conn)
	return s, nil
}
func (s *BrokerSecurityService) Close() {
	if s != nil && s.connection != nil {
		_ = s.connection.Close()
	}
}
func (s *BrokerSecurityService) Configured() bool {
	return s != nil && s.admin != nil && len(s.settings.AdminToken) >= 32 && len(s.server.Password) >= 32 && s.server.Username != "" && s.server.ClientID != ""
}
func (s *BrokerSecurityService) rpcContext(ctx context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+s.settings.AdminToken), cancel
}
func hashBrokerPassword(password string) string {
	sum := sha256.Sum256([]byte(password))
	return hex.EncodeToString(sum[:])
}

func (s *BrokerSecurityService) project(ctx context.Context, scope *BrokerSession) (*pb.Session, error) {
	valid, err := s.validate(ctx, scope)
	if err != nil {
		return nil, err
	}
	password, err := hex.DecodeString(scope.PasswordHash)
	if err != nil || len(password) != 32 {
		return nil, errors.New("invalid broker credential hash")
	}
	source, err := json.Marshal(scope)
	if err != nil {
		return nil, err
	}
	row := &pb.Session{Username: scope.Username, ClientId: scope.ClientID, PasswordSha256: password, Namespace: s.settings.Namespace, Enabled: valid, ExpiresAtMs: uint64(scope.ExpiresAt) * 1000, PolicyValidUntilMs: uint64(time.Now().Add(brokerrpc.PolicyLeaseDuration).UnixMilli()), SourceContext: source}
	if !valid {
		return row, nil
	}
	identity := &pb.PayloadPolicy{CaseInsensitiveKeys: true, Bindings: []*pb.JsonBinding{
		{Paths: []string{"/from/type", "/sender_type"}, EqualsString: scope.ActorType, RequiredAny: s.settings.RequireMessageIdentity},
		{Paths: []string{"/from/id", "/sender_id"}, EqualsString: scope.ActorID.String(), RequiredAny: s.settings.RequireMessageIdentity},
		{Paths: []string{"/conversation_id", "/topic"}, EqualsTopic: true},
	}}
	for _, action := range []pb.Action{pb.Action_SUBSCRIBE, pb.Action_PUBLISH} {
		topics := scope.Subscribe
		if action == pb.Action_PUBLISH {
			topics = scope.Publish
		}
		for _, topic := range topics {
			allowed, err := s.topicAllowed(ctx, scope, topic)
			if err != nil {
				return nil, err
			}
			if !allowed {
				continue
			}
			rule := &pb.Permission{Action: action, TopicFilter: topic}
			if action == pb.Action_PUBLISH && strings.HasPrefix(topic, "chat/") {
				rule.PayloadPolicy = identity
			}
			row.Permissions = append(row.Permissions, rule)
		}
	}
	return row, nil
}

func (s *BrokerSecurityService) Mint(ctx context.Context, scope BrokerSession) (string, string, int64, error) {
	if !s.Configured() || scope.ClientID == "" || scope.ActorID == uuid.Nil || scope.OwnerID == uuid.Nil || (scope.ActorType != "user" && scope.ActorType != "bot") || (scope.ActorType == "user" && scope.ActorID != scope.OwnerID) {
		return "", "", 0, errors.New("broker security unavailable")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", "", 0, err
	}
	password := base64.RawURLEncoding.EncodeToString(secret)
	scope.Username = "pa-" + uuid.NewString()
	scope.PasswordHash = hashBrokerPassword(password)
	ttl := time.Duration(s.settings.SessionTTLSeconds) * time.Second
	if ttl < time.Minute || ttl > brokerrpc.PolicyLeaseDuration {
		ttl = brokerrpc.PolicyLeaseDuration
	}
	scope.ExpiresAt = time.Now().Add(ttl).Unix()
	for attempt := 0; attempt < 3; attempt++ {
		rpcCtx, cancel := s.rpcContext(ctx)
		snapshot, err := s.admin.ListSessions(rpcCtx, &pb.ListSessionsRequest{Namespace: s.settings.Namespace, PageSize: 1})
		cancel()
		if err != nil {
			return "", "", 0, err
		}
		row, err := s.project(ctx, &scope)
		if err != nil {
			return "", "", 0, err
		}
		if !row.Enabled {
			return "", "", 0, errors.New("broker actor inactive")
		}
		rpcCtx, cancel = s.rpcContext(ctx)
		_, err = s.admin.Apply(rpcCtx, &pb.ApplyRequest{CreateOnly: true, ExpectedVersion: snapshot.Version, Upserts: []*pb.Session{row}})
		cancel()
		if status.Code(err) == codes.Aborted {
			continue
		}
		if err != nil {
			return "", "", 0, err
		}
		return scope.Username, password, scope.ExpiresAt, nil
	}
	return "", "", 0, errors.New("broker policy changed; retry bootstrap")
}

func (s *BrokerSecurityService) serverPolicy() *pb.Session {
	hash := sha256.Sum256([]byte(s.server.Password))
	return &pb.Session{Username: s.server.Username, ClientId: s.server.ClientID, PasswordSha256: hash[:], Namespace: s.settings.Namespace, Enabled: true, PolicyValidUntilMs: uint64(time.Now().Add(brokerrpc.PolicyLeaseDuration).UnixMilli()), Permissions: []*pb.Permission{
		{Action: pb.Action_PUBLISH, TopicFilter: "agent/user/+/events"},
	}}
}

// Reconcile reads the management version before reading application policies.
// An overlapping publisher cannot replace a newer revocation with an old read.
func (s *BrokerSecurityService) Reconcile(ctx context.Context) error {
	if !s.Configured() {
		return errors.New("broker security unavailable")
	}
	s.reconcile.Lock()
	defer s.reconcile.Unlock()
	cursor := ""
	serverSeen := false
	for {
		rpcCtx, cancel := s.rpcContext(ctx)
		page, err := s.admin.ListSessions(rpcCtx, &pb.ListSessionsRequest{Namespace: s.settings.Namespace, AfterUsername: cursor, PageSize: 64})
		cancel()
		if err != nil {
			return err
		}
		update := &pb.ApplyRequest{ExpectedVersion: page.Version}
		for _, row := range page.Sessions {
			if row.Username == s.server.Username {
				serverSeen = true
				update.Upserts = append(update.Upserts, s.serverPolicy())
				continue
			}
			if row.ExpiresAtMs <= uint64(time.Now().UnixMilli()) {
				update.Deletes = append(update.Deletes, row.Username)
				continue
			}
			var scope BrokerSession
			if json.Unmarshal(row.SourceContext, &scope) != nil || scope.Username != row.Username || scope.ClientID != row.ClientId || uint64(scope.ExpiresAt)*1000 != row.ExpiresAtMs {
				return errors.New("invalid broker policy source context")
			}
			projected, err := s.project(ctx, &scope)
			if err != nil {
				return err
			}
			update.Upserts = append(update.Upserts, projected)
		}
		if len(update.Upserts)+len(update.Deletes) > 0 {
			rpcCtx, cancel = s.rpcContext(ctx)
			_, err = s.admin.Apply(rpcCtx, update)
			cancel()
			if err != nil {
				return err
			}
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
	}
	if !serverSeen {
		rpcCtx, cancel := s.rpcContext(ctx)
		defer cancel()
		_, err := s.admin.Apply(rpcCtx, &pb.ApplyRequest{CreateOnly: true, Upserts: []*pb.Session{s.serverPolicy()}})
		if status.Code(err) != codes.Aborted {
			return err
		}
	}
	return nil
}
func (s *BrokerSecurityService) NotifyPermissionsChanged() {
	if s == nil {
		return
	}
	select {
	case s.notify <- struct{}{}:
	default:
	}
}
func (s *BrokerSecurityService) Run(ctx context.Context, onError func(error)) {
	if !s.Configured() {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	s.NotifyPermissionsChanged()
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.notify:
		case <-ticker.C:
		}
		// Coalesced notifications and a single writer avoid one goroutine per change.
		for attempt := 0; attempt < 3; attempt++ {
			err := s.Reconcile(ctx)
			if err == nil {
				break
			}
			if status.Code(err) == codes.Aborted {
				continue
			}
			if onError != nil {
				onError(err)
			}
			break
		}
	}
}
