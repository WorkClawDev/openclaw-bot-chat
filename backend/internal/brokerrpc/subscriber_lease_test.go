package brokerrpc

import (
	"context"
	"strings"
	"testing"
	"time"

	pb "github.com/openclaw-bot-chat/backend/internal/brokerrpc/authzv1"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type leaseRPC struct {
	row               *pb.Session
	foreign, conflict bool
	calls             int
	t                 *testing.T
}

func (f *leaseRPC) ListSessions(ctx context.Context, r *pb.ListSessionsRequest, _ ...grpc.CallOption) (*pb.ListSessionsResponse, error) {
	f.t.Helper()
	md, _ := metadata.FromOutgoingContext(ctx)
	if len(md.Get("authorization")) != 1 {
		f.t.Fatal("missing management authentication")
	}
	if !strings.HasPrefix(r.Namespace, "app:ingest:") {
		f.t.Fatal("consumer queried business policy namespace")
	}
	result := &pb.ListSessionsResponse{Version: "version"}
	if f.row != nil && !f.foreign {
		result.Sessions = []*pb.Session{f.row}
	}
	return result, nil
}
func (f *leaseRPC) Apply(_ context.Context, r *pb.ApplyRequest, _ ...grpc.CallOption) (*pb.ApplyResponse, error) {
	f.calls++
	if f.conflict {
		f.conflict = false
		return nil, status.Error(codes.Aborted, "concurrent update")
	}
	if f.foreign {
		if !r.CreateOnly {
			f.t.Fatal("overwrote another namespace")
		}
		return nil, status.Error(codes.Aborted, "identity exists")
	}
	if r.CreateOnly != (f.row == nil) || r.ExpectedVersion != "version" {
		f.t.Fatal("invalid ownership/CAS")
	}
	f.row = proto.Clone(r.Upserts[0]).(*pb.Session)
	return &pb.ApplyResponse{}, nil
}
func TestIndependentSubscriberLeaseScopeAndCAS(t *testing.T) {
	s, err := NewSubscriberLease(config.BrokerSecurityConfig{Address: "127.0.0.1:1", Insecure: true, AdminToken: strings.Repeat("a", 40), Namespace: "app"}, config.MQTTConfig{Username: "ingest", ClientID: "ingest-1", Password: strings.Repeat("p", 40), TopicPrefix: "chat"})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	f := &leaseRPC{t: t, conflict: true}
	s.admin = f
	if err := s.Renew(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.calls != 2 || f.row.ExpiresAtMs != 0 || f.row.PolicyValidUntilMs > uint64(time.Now().Add(5*time.Minute).UnixMilli()) {
		t.Fatal("lease is unbounded or conflict not retried")
	}
	if len(f.row.Permissions) != 1 || f.row.Permissions[0].Action != pb.Action_SUBSCRIBE || f.row.Permissions[0].TopicFilter != "chat/#" {
		t.Fatal("consumer can publish")
	}
	old := f.row.PolicyValidUntilMs
	if err := s.Renew(context.Background()); err != nil || f.row.PolicyValidUntilMs < old {
		t.Fatal("independent renewal failed", err)
	}
	f.foreign = true
	if err := s.Renew(context.Background()); err == nil {
		t.Fatal("foreign username was accepted")
	}
}
