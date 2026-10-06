package brokerrpc

import (
	"context"
	"crypto/sha256"
	"errors"
	"strings"
	"time"

	pb "github.com/openclaw-bot-chat/backend/internal/brokerrpc/authzv1"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// SubscriberLease projects only the independent consumer's own static identity.
// Its namespace must differ from the API's business session namespace.
type SubscriberLease struct {
	admin pb.AdministrationClient
	conn  *grpc.ClientConn
	token string
	row   *pb.Session
}

func NewSubscriberLease(settings config.BrokerSecurityConfig, mqtt config.MQTTConfig) (*SubscriberLease, error) {
	if settings.Address == "" || len(settings.AdminToken) < 32 || len(mqtt.Password) < 32 || mqtt.Username == "" || mqtt.ClientID == "" {
		return nil, errors.New("ingest requires authz RPC and a dedicated MQTT identity with secrets of at least 32 characters")
	}
	if settings.Namespace == "" {
		settings.Namespace = "openclaw"
	}
	if mqtt.TopicPrefix == "" {
		mqtt.TopicPrefix = "chat"
	}
	if strings.ContainsAny(mqtt.TopicPrefix, "+#") {
		return nil, errors.New("invalid ingest topic prefix")
	}
	conn, err := Dial(settings)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256([]byte(mqtt.Password))
	return &SubscriberLease{admin: pb.NewAdministrationClient(conn), conn: conn, token: settings.AdminToken, row: &pb.Session{
		Username: mqtt.Username, ClientId: mqtt.ClientID, PasswordSha256: hash[:], Enabled: true,
		Namespace:   settings.Namespace + ":ingest:" + mqtt.ClientID,
		Permissions: []*pb.Permission{{Action: pb.Action_SUBSCRIBE, TopicFilter: strings.TrimSuffix(mqtt.TopicPrefix, "/") + "/#"}},
	}}, nil
}
func (s *SubscriberLease) Close() {
	if s.conn != nil {
		_ = s.conn.Close()
	}
}
func (s *SubscriberLease) Renew(ctx context.Context) error {
	for attempt := 0; attempt < 3; attempt++ {
		call, cancel := context.WithTimeout(ctx, 3*time.Second)
		call = metadata.AppendToOutgoingContext(call, "authorization", "Bearer "+s.token)
		page, err := s.admin.ListSessions(call, &pb.ListSessionsRequest{Namespace: s.row.Namespace, PageSize: 64})
		if err != nil {
			cancel()
			return err
		}
		found := false
		for _, row := range page.Sessions {
			if row.Username == s.row.Username {
				found = true
			}
		}
		// This namespace owns exactly one service identity. CreateOnly prevents
		// accidentally overwriting an API/user credential from another namespace.
		s.row.PolicyValidUntilMs = uint64(time.Now().Add(5 * time.Minute).UnixMilli())
		_, err = s.admin.Apply(call, &pb.ApplyRequest{ExpectedVersion: page.Version, CreateOnly: !found, Upserts: []*pb.Session{s.row}})
		cancel()
		if status.Code(err) != codes.Aborted {
			return err
		}
	}
	return errors.New("subscriber policy conflicted; use a dedicated username and namespace")
}
func (s *SubscriberLease) Run(ctx context.Context, onError func(error)) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for ctx.Err() == nil {
		if err := s.Renew(ctx); err != nil && onError != nil {
			onError(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
