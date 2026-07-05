package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestPhoneAuthHandlerCodeAndLoginWithMockSMS(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newPhoneAuthHandlerTestEnv(t)

	codeResp := doPhoneAuthRequest[phoneCodeData](t, env.router, http.MethodPost, "/api/v1/auth/phone/code", `{
		"phone": "13800138000",
		"captcha_token": "pass",
		"purpose": "login"
	}`)
	if codeResp.Code != http.StatusOK {
		t.Fatalf("code status = %d, want 200; body=%s", codeResp.Code, codeResp.Body)
	}
	if codeResp.Data.CooldownSeconds != 60 {
		t.Fatalf("cooldown_seconds = %d, want 60", codeResp.Data.CooldownSeconds)
	}
	if env.sms.LastCode != "123456" {
		t.Fatalf("mock sms code = %q, want 123456", env.sms.LastCode)
	}

	loginResp := doPhoneAuthRequest[responsedto.AuthPayloadResponse](t, env.router, http.MethodPost, "/api/v1/auth/phone/login", `{
		"phone": "13800138000",
		"code": "123456"
	}`)
	if loginResp.Code != http.StatusCreated {
		t.Fatalf("first login status = %d, want 201; body=%s", loginResp.Code, loginResp.Body)
	}
	if loginResp.Data.Tokens.AccessToken == "" || loginResp.Data.Tokens.RefreshToken == "" {
		t.Fatalf("tokens missing in response: %#v", loginResp.Data.Tokens)
	}
	if loginResp.Data.User == nil {
		t.Fatal("phone login response user is nil")
	}
	if loginResp.Data.User.Email != "" || loginResp.Data.User.Phone != "+8613800138000" {
		t.Fatalf("created phone user email=%q phone=%q, want empty email and +8613800138000", loginResp.Data.User.Email, loginResp.Data.User.Phone)
	}
	firstUserID := loginResp.Data.User.ID

	if err := env.store.Delete(httptest.NewRequest(http.MethodGet, "/", nil).Context(), "phoneauth:cooldown:86:13800138000"); err != nil {
		t.Fatalf("clear cooldown: %v", err)
	}
	_ = doPhoneAuthRequest[phoneCodeData](t, env.router, http.MethodPost, "/api/v1/auth/phone/code", `{
		"phone": "13800138000",
		"captcha_token": "pass"
	}`)
	secondLogin := doPhoneAuthRequest[responsedto.AuthPayloadResponse](t, env.router, http.MethodPost, "/api/v1/auth/phone/login", `{
		"phone": "13800138000",
		"code": "123456"
	}`)
	if secondLogin.Code != http.StatusOK {
		t.Fatalf("second login status = %d, want 200; body=%s", secondLogin.Code, secondLogin.Body)
	}
	if secondLogin.Data.User == nil || secondLogin.Data.User.ID != firstUserID {
		t.Fatalf("second login user = %#v, want existing %s", secondLogin.Data.User, firstUserID)
	}
}

func TestPhoneAuthHandlerCaptchaFailureDoesNotSendMockSMS(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newPhoneAuthHandlerTestEnv(t)

	resp := doPhoneAuthRequest[map[string]any](t, env.router, http.MethodPost, "/api/v1/auth/phone/code", `{
		"phone": "13800138000",
		"captcha_token": "fail"
	}`)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("captcha failure status = %d, want 400; body=%s", resp.Code, resp.Body)
	}
	if env.sms.LastCode != "" {
		t.Fatalf("mock sms code = %q, want no send", env.sms.LastCode)
	}
}

type phoneCodeData struct {
	CooldownSeconds int `json:"cooldown_seconds"`
}

type phoneAuthHandlerTestEnv struct {
	router *gin.Engine
	store  *service.MemoryPhoneCodeStore
	sms    *service.MockSMSProvider
}

func newPhoneAuthHandlerTestEnv(t *testing.T) phoneAuthHandlerTestEnv {
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

	store := service.NewMemoryPhoneCodeStore()
	sms := &service.MockSMSProvider{}
	phoneAuth := service.NewPhoneAuthService(
		repository.NewUserRepository(db),
		repository.NewAuditLogRepository(db),
		jwt.NewManager(jwt.Config{Secret: "test-secret", AccessTokenTTL: 7200, RefreshTokenTTL: 604800, Issuer: "test"}),
		store,
		service.MockCaptchaProvider{},
		sms,
		config.PhoneAuthConfig{
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
		},
	)

	router := gin.New()
	handler := NewAuthHandler(nil, phoneAuth)
	auth := router.Group("/api/v1/auth")
	auth.POST("/phone/code", handler.RequestPhoneCode)
	auth.POST("/phone/login", handler.PhoneLogin)

	return phoneAuthHandlerTestEnv{router: router, store: store, sms: sms}
}

type phoneAuthHTTPResult[T any] struct {
	Code int
	Body string
	Data T
}

func doPhoneAuthRequest[T any](t *testing.T, router *gin.Engine, method, path, body string) phoneAuthHTTPResult[T] {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "phone-auth-test")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	var raw struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response: %v; body=%s", err, rec.Body.String())
	}
	var data T
	if len(raw.Data) > 0 {
		if err := json.Unmarshal(raw.Data, &data); err != nil {
			t.Fatalf("decode data: %v; body=%s", err, rec.Body.String())
		}
	}
	return phoneAuthHTTPResult[T]{
		Code: rec.Code,
		Body: rec.Body.String(),
		Data: data,
	}
}
