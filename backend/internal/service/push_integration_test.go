package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/apns"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// These integration cases require a disposable localhost PostgreSQL instance.
// Each case owns and removes a separate schema; existing service data is untouched.
func pushPostgres(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := os.Getenv("PUSH_TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("PUSH_TEST_DATABASE_DSN not set: PostgreSQL push acceptance not run")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test database configuration")
	}
	if cfg.Host != "127.0.0.1" && cfg.Host != "localhost" {
		t.Fatal("push integration tests require a disposable localhost database")
	}
	base, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal("cannot connect to test database")
	}
	schema := "push_acceptance_" + uuid.New().String()[:8]
	if err := base.Exec("CREATE SCHEMA " + schema).Error; err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = base.Exec("DROP SCHEMA " + schema + " CASCADE").Error
		raw, _ := base.DB()
		_ = raw.Close()
	})
	cfg.RuntimeParams["search_path"] = schema + ",public"
	db, err := gorm.Open(postgres.New(postgres.Config{Conn: stdlib.OpenDB(*cfg)}), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal("cannot open isolated schema")
	}
	raw, _ := db.DB()
	raw.SetMaxOpenConns(5)
	t.Cleanup(func() { _ = raw.Close() })
	if err := db.AutoMigrate(&model.User{}, &model.Bot{}, &model.Group{}, &model.GroupMember{}, &model.BotGroupMember{}, &model.Message{}, &model.PushDevice{}, &model.PushDelivery{}); err != nil {
		t.Fatal(err)
	}
	return db
}

type pushTestSender struct {
	result apns.Result
	err    error
	calls  []apns.Notification
}

func (s *pushTestSender) Send(_ context.Context, n apns.Notification) (apns.Result, error) {
	s.calls = append(s.calls, n)
	return s.result, s.err
}

func pushSeed(t *testing.T, db *gorm.DB) (*repository.MessageRepository, *repository.PushRepository, model.PushDevice, model.Message) {
	t.Helper()
	user := model.User{ID: uuid.New(), Username: "push-" + uuid.NewString(), Status: model.UserStatusActive}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	bot := model.Bot{ID: uuid.New(), OwnerID: user.ID, Name: "Acceptance bot", Status: model.BotStatusEnabled}
	if err := db.Create(&bot).Error; err != nil {
		t.Fatal(err)
	}
	devices := repository.NewPushRepository(db)
	device := model.PushDevice{ID: uuid.New(), UserID: user.ID, Token: "abcdef0123456789", Environment: "sandbox", Language: "en", Enabled: true}
	if err := devices.Register(context.Background(), device, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := db.First(&device, "id = ?", device.ID).Error; err != nil {
		t.Fatal(err)
	}
	msg := model.Message{MessageID: uuid.New(), SenderType: model.SenderTypeBot, SenderID: &bot.ID, BotID: &bot.ID, ConversationID: fmt.Sprintf("chat/dm/user/%s/bot/%s", user.ID, bot.ID), MsgType: model.MsgTypeText, Content: "private message must not enter push payload"}
	msg.MQTTTopic = msg.ConversationID
	messages := repository.NewMessageRepository(db)
	messages.SetMessageCreatedHook(repository.EnqueueChatPush)
	return messages, devices, device, msg
}

func TestPushPostgresAtomicMessageOutboxAndConcurrentDuplicates(t *testing.T) {
	db := pushPostgres(t)
	messages, _, _, msg := pushSeed(t, db)
	ctx := context.Background()
	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); copy := msg; errs <- messages.CreateWithNextSeq(ctx, &copy) }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	var count int64
	db.Model(&model.Message{}).Count(&count)
	if count != 1 {
		t.Fatalf("persisted messages=%d", count)
	}
	db.Model(&model.PushDelivery{}).Count(&count)
	if count != 1 {
		t.Fatalf("queued deliveries=%d", count)
	}
	sentinel := errors.New("outbox unavailable")
	messages.SetMessageCreatedHook(func(ctx context.Context, tx *gorm.DB, m *model.Message) error {
		if err := repository.EnqueueChatPush(ctx, tx, m); err != nil {
			return err
		}
		return sentinel
	})
	msg.MessageID = uuid.New()
	if err := messages.CreateWithNextSeq(ctx, &msg); !errors.Is(err, sentinel) {
		t.Fatal("did not propagate outbox failure", err)
	}
	db.Model(&model.Message{}).Count(&count)
	if count != 1 {
		t.Fatal("message committed without outbox")
	}
	db.Model(&model.PushDelivery{}).Count(&count)
	if count != 1 {
		t.Fatal("rolled back outbox remained")
	}
}

func TestPushPostgresWorkerRetryDisableAndCurrentMembership(t *testing.T) {
	db := pushPostgres(t)
	messages, repo, device, msg := pushSeed(t, db)
	ctx := context.Background()
	sender := &pushTestSender{result: apns.Result{Retry: true, Reason: "ServiceUnavailable"}}
	worker := &PushService{Repo: repo, Sender: sender}
	newMessage := func() {
		copy := msg
		copy.ID = 0
		copy.Seq = 0
		copy.MessageID = uuid.New()
		if err := messages.CreateWithNextSeq(ctx, &copy); err != nil {
			t.Fatal(err)
		}
	}
	newMessage()
	now := time.Now().UTC()
	if worked, err := worker.DeliverNext(ctx, now); err != nil || !worked {
		t.Fatal("first attempt", err)
	}
	if worked, err := worker.DeliverNext(ctx, now.Add(time.Second)); err != nil || worked {
		t.Fatal("retried without backoff", err)
	}
	sender.result = apns.Result{Accepted: true, Reason: "Accepted"}
	if worked, err := worker.DeliverNext(ctx, now.Add(16*time.Second)); err != nil || !worked {
		t.Fatal("retry did not run", err)
	}
	if len(sender.calls) != 2 || sender.calls[0].ID != sender.calls[1].ID {
		t.Fatal("retry changed APNs dedup identity")
	}
	var accepted int64
	db.Model(&model.PushDelivery{}).Where("state = 'accepted'").Count(&accepted)
	if accepted != 1 {
		t.Fatal("acceptance state missing")
	}
	newMessage()
	if err := repo.Disable(ctx, device.UserID, device.ID, now); err != nil {
		t.Fatal(err)
	}
	if _, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if len(sender.calls) != 2 {
		t.Fatal("disabled device received queued notification")
	}
	if err := repo.Register(ctx, device, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	group := model.Group{ID: uuid.New(), OwnerID: device.UserID, Name: "Push test", IsActive: true}
	if err := db.Create(&group).Error; err != nil {
		t.Fatal(err)
	}
	botMember := model.BotGroupMember{ID: uuid.New(), GroupID: group.ID, BotID: *msg.SenderID, IsActive: true}
	if err := db.Create(&botMember).Error; err != nil {
		t.Fatal(err)
	}
	msg.ConversationID = "chat/group/" + group.ID.String()
	msg.GroupID = &group.ID
	msg.MQTTTopic = msg.ConversationID
	newMessage()
	if err := db.Delete(&botMember).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if len(sender.calls) != 2 {
		t.Fatal("removed bot's pending message was sent")
	}
	var cancelled int64
	db.Model(&model.PushDelivery{}).Where("state = 'cancelled'").Count(&cancelled)
	if cancelled != 2 {
		t.Fatal("revoked destinations not cancelled")
	}
}

func TestPushPostgresLeaseCompetitionAndAccountChange(t *testing.T) {
	db := pushPostgres(t)
	messages, repo, device, msg := pushSeed(t, db)
	ctx := context.Background()
	if err := messages.CreateWithNextSeq(ctx, &msg); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	winners := make(chan *model.PushDelivery, 10)
	errs := make(chan error, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			row, err := repo.Claim(ctx, time.Now().UTC())
			if err != nil {
				errs <- err
			}
			if row != nil {
				winners <- row
			}
		}()
	}
	wg.Wait()
	close(winners)
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if len(winners) != 1 {
		t.Fatalf("lease winners=%d", len(winners))
	}
	row := <-winners
	other := model.User{ID: uuid.New(), Username: "other-" + uuid.NewString(), Status: model.UserStatusActive}
	if err := db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	device.UserID = other.ID
	if err := repo.Register(ctx, device, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	destination, _, err := repo.Destination(ctx, row, time.Now().UTC())
	if err != nil || destination != nil {
		t.Fatal("queued message followed installation to another account", err)
	}
}

func TestPushPostgresMessageKindsExpiryRetryLimitAndInvalidToken(t *testing.T) {
	db := pushPostgres(t)
	messages, repo, device, msg := pushSeed(t, db)
	ctx := context.Background()
	sender := &pushTestSender{result: apns.Result{Accepted: true, Reason: "Accepted"}}
	worker := &PushService{Repo: repo, Sender: sender}
	for _, kind := range []model.MsgType{model.MsgTypeText, model.MsgTypeImage, model.MsgTypeAudio, model.MsgTypeFile, model.MsgTypeVideo} {
		copy := msg
		copy.MessageID = uuid.New()
		copy.MsgType = kind
		if err := messages.CreateWithNextSeq(ctx, &copy); err != nil {
			t.Fatal(err)
		}
		if worked, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil || !worked {
			t.Fatal("message kind not dispatched", kind, err)
		}
	}
	if len(sender.calls) != 5 {
		t.Fatal("not all message kinds used the same notification path")
	}
	newDelivery := func() model.PushDelivery {
		copy := msg
		copy.MessageID = uuid.New()
		if err := messages.CreateWithNextSeq(ctx, &copy); err != nil {
			t.Fatal(err)
		}
		var row model.PushDelivery
		if err := db.First(&row, "message_row_id = ?", copy.ID).Error; err != nil {
			t.Fatal(err)
		}
		return row
	}
	expired := newDelivery()
	if err := db.Model(&expired).Update("created_at", time.Now().Add(-25*time.Hour)).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := db.First(&expired, "id = ?", expired.ID).Error; err != nil {
		t.Fatal(err)
	}
	if expired.State != "expired" || len(sender.calls) != 5 {
		t.Fatal("stale message was pushed")
	}
	exhausted := newDelivery()
	if err := db.Model(&exhausted).Update("attempts", 11).Error; err != nil {
		t.Fatal(err)
	}
	sender.result = apns.Result{Retry: true, Reason: "ServiceUnavailable"}
	if _, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	db.First(&exhausted, "id = ?", exhausted.ID)
	if exhausted.State != "failed" || exhausted.Attempts != 12 {
		t.Fatal("retry limit not enforced")
	}
	invalid := newDelivery()
	sender.result = apns.Result{InvalidDevice: true, Reason: "Unregistered"}
	if _, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	db.First(&invalid, "id = ?", invalid.ID)
	db.First(&device, "id = ?", device.ID)
	if invalid.State != "failed" || device.Enabled {
		t.Fatal("invalid token not stopped")
	}
	count := len(sender.calls)
	msg.MessageID = uuid.New()
	if err := messages.CreateWithNextSeq(ctx, &msg); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil || worked || len(sender.calls) != count {
		t.Fatal("invalid device was enqueued again")
	}
}

func TestPushPostgresMigrationAndMembershipRevocation(t *testing.T) {
	db := pushPostgres(t)
	ctx := context.Background()
	// All tables here belong to this test's private schema.
	if err := db.Exec("DROP TABLE push_deliveries, push_devices").Error; err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../../migrations/20261004_chat_push.sql")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := db.Exec(string(migration)).Error; err != nil {
			t.Fatal("migration must be idempotent", err)
		}
	}
	messages, repo, device, msg := pushSeed(t, db)
	owner := model.User{ID: uuid.New(), Username: "owner-" + uuid.NewString(), Status: model.UserStatusActive}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatal(err)
	}
	group := model.Group{ID: uuid.New(), Name: "Membership", OwnerID: owner.ID, IsActive: true}
	if err := db.Create(&group).Error; err != nil {
		t.Fatal(err)
	}
	member := model.GroupMember{ID: uuid.New(), GroupID: group.ID, UserID: device.UserID, IsActive: true}
	if err := db.Create(&member).Error; err != nil {
		t.Fatal(err)
	}
	botMember := model.BotGroupMember{ID: uuid.New(), GroupID: group.ID, BotID: *msg.SenderID, IsActive: true}
	if err := db.Create(&botMember).Error; err != nil {
		t.Fatal(err)
	}
	msg.ConversationID = "chat/group/" + group.ID.String()
	msg.MQTTTopic = msg.ConversationID
	msg.GroupID = &group.ID
	if err := messages.CreateWithNextSeq(ctx, &msg); err != nil {
		t.Fatal(err)
	}
	if err := db.Delete(&member).Error; err != nil {
		t.Fatal(err)
	}
	sender := &pushTestSender{result: apns.Result{Accepted: true, Reason: "Accepted"}}
	worker := &PushService{Repo: repo, Sender: sender}
	if worked, err := worker.DeliverNext(ctx, time.Now().UTC()); err != nil || !worked {
		t.Fatal(err)
	}
	if len(sender.calls) != 0 {
		t.Fatal("former group member received queued notification")
	}
	var row model.PushDelivery
	if err := db.First(&row, "message_row_id = ?", msg.ID).Error; err != nil {
		t.Fatal(err)
	}
	if row.State != "cancelled" {
		t.Fatal("removed member delivery not cancelled")
	}
}
