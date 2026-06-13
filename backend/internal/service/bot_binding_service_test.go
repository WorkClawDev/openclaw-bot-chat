package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestBotBindingTokenCreatePreviewConfirm(t *testing.T) {
	env := newBotBindingServiceTestEnv(t)
	ctx := context.Background()

	binding, err := env.service.CreateBindingToken(ctx, env.botID, env.ownerID)
	if err != nil {
		t.Fatalf("CreateBindingToken() error = %v", err)
	}
	if binding.Token == "" || len(binding.Token) < 14 {
		t.Fatalf("CreateBindingToken() token = %q", binding.Token)
	}
	if binding.Bot == nil || binding.Bot.ID != env.botID {
		t.Fatalf("CreateBindingToken() bot = %#v, want %s", binding.Bot, env.botID)
	}
	if !binding.ExpiresAt.After(time.Now()) {
		t.Fatalf("CreateBindingToken() expires_at = %s, want future", binding.ExpiresAt)
	}

	previewBot, _, err := env.service.PreviewBindingToken(ctx, binding.Token, env.ownerID)
	if err != nil {
		t.Fatalf("PreviewBindingToken() error = %v", err)
	}
	if previewBot.ID != env.botID {
		t.Fatalf("PreviewBindingToken() bot = %s, want %s", previewBot.ID, env.botID)
	}

	confirmedBot, err := env.service.ConfirmBindingToken(ctx, binding.Token, env.ownerID)
	if err != nil {
		t.Fatalf("ConfirmBindingToken() error = %v", err)
	}
	if confirmedBot.ID != env.botID {
		t.Fatalf("ConfirmBindingToken() bot = %s, want %s", confirmedBot.ID, env.botID)
	}

	if _, err := env.service.ConfirmBindingToken(ctx, binding.Token, env.ownerID); !errors.Is(err, ErrBindingTokenUsed) {
		t.Fatalf("second ConfirmBindingToken() error = %v, want ErrBindingTokenUsed", err)
	}
}

func TestBotBindingTokenRejectsWrongUserAndTampering(t *testing.T) {
	env := newBotBindingServiceTestEnv(t)
	ctx := context.Background()

	binding, err := env.service.CreateBindingToken(ctx, env.botID, env.ownerID)
	if err != nil {
		t.Fatalf("CreateBindingToken() error = %v", err)
	}

	if _, _, err := env.service.PreviewBindingToken(ctx, binding.Token, uuid.New()); !errors.Is(err, ErrBindingTokenInvalid) {
		t.Fatalf("PreviewBindingToken() wrong user error = %v, want ErrBindingTokenInvalid", err)
	}

	tampered := binding.Token[:len(binding.Token)-1] + "x"
	if _, _, err := env.service.PreviewBindingToken(ctx, tampered, env.ownerID); !errors.Is(err, ErrBindingTokenInvalid) {
		t.Fatalf("PreviewBindingToken() tampered error = %v, want ErrBindingTokenInvalid", err)
	}
}

type botBindingServiceTestEnv struct {
	service *BotService
	ownerID uuid.UUID
	botID   uuid.UUID
}

func newBotBindingServiceTestEnv(t *testing.T) botBindingServiceTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE bots (
			id text PRIMARY KEY,
			owner_id text NOT NULL,
			name text NOT NULL,
			description text,
			avatar_url text,
			bot_type text NOT NULL DEFAULT 'general',
			status integer NOT NULL DEFAULT 1,
			is_public boolean NOT NULL DEFAULT false,
			config text,
			mqtt_topic text,
			created_at datetime,
			updated_at datetime,
			deleted_at datetime
		);
		CREATE TABLE bot_keys (
			id text PRIMARY KEY,
			bot_id text NOT NULL,
			key_prefix text NOT NULL,
			key_hash text NOT NULL,
			name text,
			last_used_at datetime,
			last_used_ip text,
			expires_at datetime,
			is_active boolean NOT NULL DEFAULT true,
			created_at datetime
		);
		CREATE TABLE bot_binding_tokens (
			id text PRIMARY KEY,
			bot_id text NOT NULL,
			owner_id text NOT NULL,
			prefix text NOT NULL UNIQUE,
			token_hash text NOT NULL,
			expires_at datetime NOT NULL,
			used_at datetime,
			created_at datetime
		);
		CREATE TABLE audit_logs (
			id text PRIMARY KEY,
			user_id text,
			bot_id text,
			action text NOT NULL,
			resource_type text,
			resource_id text,
			ip_address text,
			user_agent text,
			response_code integer,
			created_at datetime
		)
	`).Error; err != nil {
		t.Fatalf("migrate test tables: %v", err)
	}

	ownerID := uuid.New()
	botID := uuid.New()
	bot := model.Bot{
		ID:        botID,
		OwnerID:   ownerID,
		Name:      "Doc Bot",
		BotType:   model.BotTypeGeneral,
		Status:    model.BotStatusEnabled,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
	if err := db.Create(&bot).Error; err != nil {
		t.Fatalf("seed bot: %v", err)
	}

	return botBindingServiceTestEnv{
		service: NewBotService(
			repository.NewBotRepository(db),
			repository.NewBotKeyRepository(db),
			repository.NewBotBindingTokenRepository(db),
			repository.NewAuditLogRepository(db),
		),
		ownerID: ownerID,
		botID:   botID,
	}
}
