package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Uses the production repository constructor and queued-message path, with an
// isolated schema. It does not need an API process or an APNs provider key.
func TestQueuedMessagePushOutbox(t *testing.T) {
	dsn := os.Getenv("PUSH_TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("PUSH_TEST_DATABASE_DSN not set: real PostgreSQL ingestion not run")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test database configuration")
	}
	if (cfg.Host != "127.0.0.1" && cfg.Host != "localhost") || (!strings.HasSuffix(cfg.Database, "_test") && !strings.HasSuffix(cfg.Database, "_acceptance")) {
		t.Fatal("require isolated localhost test database")
	}
	base, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal("cannot connect to isolated database")
	}
	raw, _ := base.DB()
	defer raw.Close()
	schema := "ingest_push_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if err := base.Exec("CREATE SCHEMA " + schema).Error; err != nil {
		t.Fatal(err)
	}
	defer base.Exec("DROP SCHEMA " + schema + " CASCADE")
	cfg.RuntimeParams["search_path"] = schema + ",public"
	db, err := gorm.Open(postgres.New(postgres.Config{Conn: stdlib.OpenDB(*cfg)}), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	conn, _ := db.DB()
	defer conn.Close()
	if err := db.AutoMigrate(&model.User{}, &model.Bot{}, &model.Message{}, &model.PushDevice{}, &model.PushDelivery{}); err != nil {
		t.Fatal(err)
	}
	user := model.User{ID: uuid.New(), Username: "ingest-" + uuid.NewString(), Status: model.UserStatusActive}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	bot := model.Bot{ID: uuid.New(), OwnerID: user.ID, Name: "Ingest fixture", Status: model.BotStatusEnabled}
	if err := db.Create(&bot).Error; err != nil {
		t.Fatal(err)
	}
	device := model.PushDevice{ID: uuid.New(), UserID: user.ID, Token: "abcdef", Environment: "sandbox", Language: "en", Enabled: true}
	if err := repository.NewPushRepository(db).Register(context.Background(), device, time.Now()); err != nil {
		t.Fatal(err)
	}
	topic := fmt.Sprintf("chat/dm/user/%s/bot/%s", user.ID, bot.ID)
	handle := func(enabled bool, id uuid.UUID) error {
		payload, _ := json.Marshal(map[string]any{"id": id.String(), "topic": topic, "conversation_id": topic, "timestamp": time.Now().Unix(), "from": map[string]string{"type": "bot", "id": bot.ID.String()}, "to": map[string]string{"type": "user", "id": user.ID.String()}, "content": map[string]string{"type": "text", "body": "private fixture text"}})
		messages := service.NewMessageService(messageRepository(db, enabled), repository.NewBotRepository(db), repository.NewGroupRepository(db), nil, nil, nil)
		return messages.HandleQueuedMessage(context.Background(), topic, payload, id, time.Now())
	}
	count := func(table any, want int64) {
		t.Helper()
		var got int64
		if err := db.Model(table).Count(&got).Error; err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("count %T = %d, want %d", table, got, want)
		}
	}
	if err := handle(false, uuid.New()); err != nil {
		t.Fatal(err)
	}
	count(&model.Message{}, 1)
	count(&model.PushDelivery{}, 0)
	id := uuid.New()
	if err := handle(true, id); err != nil {
		t.Fatal(err)
	}
	// New constructor represents a restarted independent consumer, replaying the
	// same broker delivery. No duplicate message or notification may be inserted.
	if err := handle(true, id); err != nil {
		t.Fatal(err)
	}
	count(&model.Message{}, 2)
	count(&model.PushDelivery{}, 1)
	retryID := uuid.New()
	// A missing table could fall through to public while another acceptance
	// API runs. Inject a transient error only into this schema's outbox.
	if err := db.Exec("CREATE FUNCTION " + schema + ".retry_push() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'isolated queue retry' USING ERRCODE='40001'; END $$").Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("CREATE TRIGGER retry_push BEFORE INSERT ON " + schema + ".push_deliveries FOR EACH ROW EXECUTE FUNCTION " + schema + ".retry_push()").Error; err != nil {
		t.Fatal(err)
	}
	if err := handle(true, retryID); err == nil {
		t.Fatal("outbox failure was acknowledged")
	} else {
		var permanent *service.PermanentMessageError
		if errors.As(err, &permanent) {
			t.Fatal("transient outbox failure marked permanent")
		}
	}
	count(&model.Message{}, 2)
	if err := db.Exec("DROP TRIGGER retry_push ON " + schema + ".push_deliveries").Error; err != nil {
		t.Fatal(err)
	}
	if err := handle(true, retryID); err != nil {
		t.Fatal(err)
	}
	count(&model.Message{}, 3)
	count(&model.PushDelivery{}, 2)
	var message model.Message
	if err := db.First(&message, "message_id = ?", retryID).Error; err != nil {
		t.Fatal(err)
	}
	if message.Seq != 3 {
		t.Fatalf("failed transaction consumed sequence: %d", message.Seq)
	}
}
