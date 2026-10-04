package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"github.com/google/uuid"
	pb "github.com/openclaw-bot-chat/backend/internal/brokerrpc/authzv1"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"strings"
	"testing"
	"time"
)

type projectionRPC struct {
	rows      []*pb.Session
	calls     []*pb.ApplyRequest
	broken    bool
	conflict  bool
	queryRead func()
	token     string
}

func (f *projectionRPC) ListSessions(ctx context.Context, req *pb.ListSessionsRequest, _ ...grpc.CallOption) (*pb.ListSessionsResponse, error) {
	md, _ := metadata.FromOutgoingContext(ctx)
	if len(md.Get("authorization")) != 1 || md.Get("authorization")[0] != "Bearer "+f.token {
		return nil, errors.New("missing admin credential")
	}
	if f.broken {
		return nil, errors.New("RPC offline")
	}
	if f.queryRead != nil {
		f.queryRead()
	}
	rows := make([]*pb.Session, len(f.rows))
	for i, r := range f.rows {
		rows[i] = proto.Clone(r).(*pb.Session)
	}
	return &pb.ListSessionsResponse{Version: "before-policy-read", Sessions: rows}, nil
}
func (f *projectionRPC) Apply(ctx context.Context, req *pb.ApplyRequest, _ ...grpc.CallOption) (*pb.ApplyResponse, error) {
	if f.broken {
		return nil, errors.New("RPC offline")
	}
	if f.conflict {
		f.conflict = false
		return nil, status.Error(codes.Aborted, "changed")
	}
	f.calls = append(f.calls, proto.Clone(req).(*pb.ApplyRequest))
	return &pb.ApplyResponse{Version: "next"}, nil
}
func publisherFixture() (*BrokerSecurityService, *projectionRPC) {
	token := strings.Repeat("a", 40)
	f := &projectionRPC{token: token}
	s := &BrokerSecurityService{admin: f, notify: make(chan struct{}, 1), settings: config.BrokerSecurityConfig{AdminToken: token, Namespace: "fixture", SessionTTLSeconds: 300, RequireMessageIdentity: true}, server: config.MQTTConfig{Username: "server", ClientID: "server-id", Password: strings.Repeat("p", 40)}, validate: func(context.Context, *BrokerSession) (bool, error) { return true, nil }, topicAllowed: func(context.Context, *BrokerSession, string) (bool, error) { return true, nil }}
	return s, f
}
func TestMintPublishesBoundedGenericPolicyAndHash(t *testing.T) {
	s, f := publisherFixture()
	actor := uuid.New()
	read := false
	f.queryRead = func() { read = true }
	s.validate = func(context.Context, *BrokerSession) (bool, error) {
		if !read {
			t.Fatal("policy read preceded version capture")
		}
		return true, nil
	}
	name, password, expiry, err := s.Mint(context.Background(), BrokerSession{ClientID: "client", ActorType: "user", ActorID: actor, OwnerID: actor, Subscribe: []string{"chat/group/g"}, Publish: []string{"chat/group/g"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 1 {
		t.Fatal("missing management write")
	}
	update := f.calls[0]
	row := update.Upserts[0]
	hash := sha256.Sum256([]byte(password))
	if !update.CreateOnly || update.ExpectedVersion == "" || row.Username != name || row.ClientId != "client" || !bytes.Equal(row.PasswordSha256, hash[:]) || row.ExpiresAtMs != uint64(expiry)*1000 || expiry > time.Now().Add(5*time.Minute).Unix() {
		t.Fatal("invalid bounded credentials")
	}
	if bytes.Contains(row.SourceContext, []byte(password)) {
		t.Fatal("raw password persisted")
	}
	if len(row.Permissions) != 2 || row.Permissions[1].PayloadPolicy == nil || !row.Permissions[1].PayloadPolicy.CaseInsensitiveKeys {
		t.Fatal("missing message identity projection")
	}
	binding := row.Permissions[1].PayloadPolicy.Bindings[1]
	if binding.EqualsString != actor.String() || !binding.RequiredAny {
		t.Fatal("identity binding lost")
	}
	f.broken = true
	if _, _, _, err = s.Mint(context.Background(), BrokerSession{ClientID: "x", ActorType: "user", ActorID: actor, OwnerID: actor}); err == nil {
		t.Fatal("credential issued during RPC outage")
	}
}
func TestProjectionRevokesScopesWithoutExtendingSession(t *testing.T) {
	s, f := publisherFixture()
	actor := uuid.New()
	_, _, _, err := s.Mint(context.Background(), BrokerSession{ClientID: "client", ActorType: "user", ActorID: actor, OwnerID: actor, Publish: []string{"chat/group/g", "chat/group/keep"}})
	if err != nil {
		t.Fatal(err)
	}
	old := f.calls[0].Upserts[0]
	f.rows = []*pb.Session{old, s.serverPolicy()}
	f.calls = nil
	s.topicAllowed = func(_ context.Context, _ *BrokerSession, topic string) (bool, error) {
		return topic != "chat/group/g", nil
	}
	if err = s.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	row := f.calls[0].Upserts[0]
	if len(row.Permissions) != 1 || row.Permissions[0].TopicFilter != "chat/group/keep" || row.ExpiresAtMs != old.ExpiresAtMs {
		t.Fatal("scope revocation/expiry broken")
	}
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return false, nil }
	f.calls = nil
	if err = s.Reconcile(context.Background()); err != nil || f.calls[0].Upserts[0].Enabled {
		t.Fatal("inactive actor still enabled", err)
	}
	s.validate = func(context.Context, *BrokerSession) (bool, error) { return false, errors.New("database unavailable") }
	f.calls = nil
	if err = s.Reconcile(context.Background()); err == nil || len(f.calls) != 0 {
		t.Fatal("DB failure renewed policy")
	}
}
func TestProjectionCASRetryAndCoalescedNotifications(t *testing.T) {
	s, f := publisherFixture()
	f.conflict = true
	actor := uuid.New()
	if _, _, _, err := s.Mint(context.Background(), BrokerSession{ClientID: "client", ActorType: "user", ActorID: actor, OwnerID: actor}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10000; i++ {
		s.NotifyPermissionsChanged()
	}
	if len(s.notify) != 1 {
		t.Fatal("notifications unbounded")
	}
	server := s.serverPolicy()
	if server.ExpiresAtMs != 0 || server.PolicyValidUntilMs > uint64(time.Now().Add(5*time.Minute).UnixMilli()) || len(server.Permissions) != 3 {
		t.Fatal("server lease or scope unbounded")
	}
}
