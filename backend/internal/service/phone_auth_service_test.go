package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestNormalizeMainlandPhone(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "plain", input: "13800138000", want: "13800138000"},
		{name: "plus86", input: "+86 138-0013-8000", want: "13800138000"},
		{name: "zerozero86", input: "008613800138000", want: "13800138000"},
		{name: "invalid prefix", input: "12800138000", wantErr: true},
		{name: "too short", input: "1380013800", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			country, phone, err := NormalizeMainlandPhone(tt.input)
			if tt.wantErr {
				if !errors.Is(err, ErrInvalidPhone) {
					t.Fatalf("NormalizeMainlandPhone() error = %v, want ErrInvalidPhone", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("NormalizeMainlandPhone() error = %v", err)
			}
			if country != "86" || phone != tt.want {
				t.Fatalf("NormalizeMainlandPhone() = %s %s, want 86 %s", country, phone, tt.want)
			}
		})
	}
}

func TestPhoneCodeRequiresCaptchaBeforeSMS(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	err := env.service.RequestCode(context.Background(), PhoneCodeRequest{
		Phone:        "13800138000",
		CaptchaToken: "fail",
		Purpose:      "login",
	}, "127.0.0.1", "test")

	if !errors.Is(err, ErrCaptchaInvalid) {
		t.Fatalf("RequestCode() error = %v, want ErrCaptchaInvalid", err)
	}
	if env.sms.LastCode != "" {
		t.Fatalf("sms sent code = %q, want no send", env.sms.LastCode)
	}
}

func TestPhoneCodeSendCooldownRateLimit(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	ctx := context.Background()
	req := PhoneCodeRequest{Phone: "13800138000", CaptchaToken: "pass", Purpose: "login"}
	if err := env.service.RequestCode(ctx, req, "127.0.0.1", "test"); err != nil {
		t.Fatalf("first RequestCode() error = %v", err)
	}

	err := env.service.RequestCode(ctx, req, "127.0.0.1", "test")
	if !errors.Is(err, ErrPhoneRateLimited) {
		t.Fatalf("second RequestCode() error = %v, want ErrPhoneRateLimited", err)
	}
}

func TestPhoneLoginCreatesAndThenReusesUser(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	ctx := context.Background()
	phone := "13800138000"

	if err := env.service.RequestCode(ctx, PhoneCodeRequest{Phone: phone, CaptchaToken: "pass"}, "127.0.0.1", "test"); err != nil {
		t.Fatalf("RequestCode() error = %v", err)
	}
	tokens, user, created, err := env.service.LoginOrRegister(ctx, PhoneLoginRequest{Phone: phone, Code: "123456"}, "127.0.0.1", "test")
	if err != nil {
		t.Fatalf("LoginOrRegister() error = %v", err)
	}
	if !created {
		t.Fatal("LoginOrRegister() created = false, want true")
	}
	if tokens.AccessToken == "" || tokens.RefreshToken == "" {
		t.Fatalf("tokens missing: %#v", tokens)
	}
	if user.PhoneNumber == nil || *user.PhoneNumber != phone || user.Email != nil || user.PasswordHash != nil {
		t.Fatalf("created user = %#v, want phone-only user", user)
	}

	_ = env.store.Delete(ctx, "phoneauth:cooldown:86:"+phone)
	if err := env.service.RequestCode(ctx, PhoneCodeRequest{Phone: phone, CaptchaToken: "pass"}, "127.0.0.1", "test"); err != nil {
		t.Fatalf("second RequestCode() error = %v", err)
	}
	_, reused, created, err := env.service.LoginOrRegister(ctx, PhoneLoginRequest{Phone: phone, Code: "123456"}, "127.0.0.1", "test")
	if err != nil {
		t.Fatalf("second LoginOrRegister() error = %v", err)
	}
	if created || reused.ID != user.ID {
		t.Fatalf("second LoginOrRegister() created=%v user=%s, want existing %s", created, reused.ID, user.ID)
	}
}

func TestPhoneCodeMaxAttemptsInvalidatesCode(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	env.service.cfg.MaxVerifyAttempts = 2
	ctx := context.Background()
	phone := "13800138000"

	if err := env.service.RequestCode(ctx, PhoneCodeRequest{Phone: phone, CaptchaToken: "pass"}, "127.0.0.1", "test"); err != nil {
		t.Fatalf("RequestCode() error = %v", err)
	}
	for i := 0; i < 3; i++ {
		_, _, _, err := env.service.LoginOrRegister(ctx, PhoneLoginRequest{Phone: phone, Code: "000000"}, "127.0.0.1", "test")
		if !errors.Is(err, ErrInvalidPhoneCode) {
			t.Fatalf("wrong LoginOrRegister() error = %v, want ErrInvalidPhoneCode", err)
		}
	}
	_, _, _, err := env.service.LoginOrRegister(ctx, PhoneLoginRequest{Phone: phone, Code: "123456"}, "127.0.0.1", "test")
	if !errors.Is(err, ErrInvalidPhoneCode) {
		t.Fatalf("correct after max attempts error = %v, want ErrInvalidPhoneCode", err)
	}
}

type phoneAuthServiceTestEnv struct {
	service *PhoneAuthService
	store   *MemoryPhoneCodeStore
	sms     *MockSMSProvider
}

func newPhoneAuthServiceTestEnv(t *testing.T) phoneAuthServiceTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE users (
			id text PRIMARY KEY,
			username text NOT NULL UNIQUE,
			email text UNIQUE,
			password_hash text,
			phone_country_code text,
			phone_number text,
			phone_verified_at datetime,
			auth_provider text NOT NULL DEFAULT 'password',
			nickname text,
			avatar_url text,
			status integer NOT NULL DEFAULT 1,
			is_deleted boolean NOT NULL DEFAULT false,
			last_login_at datetime,
			last_login_ip text,
			created_at datetime,
			updated_at datetime,
			deleted_at datetime
		);
		CREATE UNIQUE INDEX idx_users_phone ON users(phone_country_code, phone_number)
			WHERE phone_country_code IS NOT NULL AND phone_number IS NOT NULL AND deleted_at IS NULL;
		CREATE TABLE audit_logs (
			id integer PRIMARY KEY AUTOINCREMENT,
			event_id text,
			user_id text,
			bot_id text,
			group_id text,
			action text NOT NULL,
			resource_type text,
			resource_id text,
			ip_address text,
			user_agent text,
			request_method text,
			request_path text,
			request_body text,
			response_code integer,
			error_message text,
			metadata text,
			created_at datetime
		);
	`).Error; err != nil {
		t.Fatalf("create schema: %v", err)
	}

	store := NewMemoryPhoneCodeStore()
	sms := &MockSMSProvider{}
	cfg := config.PhoneAuthConfig{
		Enabled:             true,
		AllowedCountryCodes: []string{"86"},
		CodeTTLSeconds:      300,
		SendCooldownSeconds: 60,
		PhoneHourlyLimit:    5,
		PhoneDailyLimit:     10,
		IPHourlyLimit:       30,
		MaxVerifyAttempts:   5,
		CodePepper:          "test-pepper",
		MockCode:            "123456",
	}
	return phoneAuthServiceTestEnv{
		service: NewPhoneAuthService(
			repository.NewUserRepository(db),
			repository.NewAuditLogRepository(db),
			jwt.NewManager(jwt.Config{Secret: "test-secret", AccessTokenTTL: 7200, RefreshTokenTTL: 604800, Issuer: "test"}),
			store,
			MockCaptchaProvider{},
			sms,
			cfg,
		),
		store: store,
		sms:   sms,
	}
}
