package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestBotBindingHandlerCreatePreviewConfirm(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newBotBindingHandlerTestEnv(t)
	router := env.routerForUser(env.ownerID)

	createResp := doBotBindingRequest[responsedto.BotBindingResponse](t, router, http.MethodPost, "/bots/"+env.botID.String()+"/bindings", "")
	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body=%s", createResp.Code, http.StatusCreated, createResp.Body)
	}
	if createResp.Payload.Data.Token == "" {
		t.Fatal("create response did not include one-time token")
	}
	if strings.Contains(createResp.Payload.Data.BindURL, "ocbk_") {
		t.Fatalf("bind url leaked bot key: %s", createResp.Payload.Data.BindURL)
	}
	if !strings.Contains(createResp.Payload.Data.BindURL, "token=") {
		t.Fatalf("bind url = %q, want token query", createResp.Payload.Data.BindURL)
	}

	previewResp := doBotBindingRequest[responsedto.BotBindingResponse](
		t,
		router,
		http.MethodGet,
		"/bot-bindings/preview?token="+createResp.Payload.Data.Token,
		"",
	)
	if previewResp.Code != http.StatusOK {
		t.Fatalf("preview status = %d, want %d; body=%s", previewResp.Code, http.StatusOK, previewResp.Body)
	}
	if previewResp.Payload.Data.Token != "" {
		t.Fatalf("preview leaked token = %q", previewResp.Payload.Data.Token)
	}
	if previewResp.Payload.Data.Bot == nil || previewResp.Payload.Data.Bot.ID != env.botID {
		t.Fatalf("preview bot = %#v, want %s", previewResp.Payload.Data.Bot, env.botID)
	}

	confirmBody := `{"token":"` + createResp.Payload.Data.Token + `"}`
	confirmResp := doBotBindingRequest[responsedto.BotBindingResponse](t, router, http.MethodPost, "/bot-bindings/confirm", confirmBody)
	if confirmResp.Code != http.StatusOK {
		t.Fatalf("confirm status = %d, want %d; body=%s", confirmResp.Code, http.StatusOK, confirmResp.Body)
	}
	if confirmResp.Payload.Data.Bot == nil || confirmResp.Payload.Data.Bot.ID != env.botID {
		t.Fatalf("confirm bot = %#v, want %s", confirmResp.Payload.Data.Bot, env.botID)
	}

	reuseResp := doBotBindingRequest[map[string]any](t, router, http.MethodPost, "/bot-bindings/confirm", confirmBody)
	if reuseResp.Code != http.StatusBadRequest {
		t.Fatalf("reuse status = %d, want %d; body=%s", reuseResp.Code, http.StatusBadRequest, reuseResp.Body)
	}
}

func TestBotBindingHandlerRejectsOtherUser(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newBotBindingHandlerTestEnv(t)
	ownerRouter := env.routerForUser(env.ownerID)
	otherRouter := env.routerForUser(uuid.New())

	createResp := doBotBindingRequest[responsedto.BotBindingResponse](t, ownerRouter, http.MethodPost, "/bots/"+env.botID.String()+"/bindings", "")
	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body=%s", createResp.Code, http.StatusCreated, createResp.Body)
	}
	otherResp := doBotBindingRequest[map[string]any](
		t,
		otherRouter,
		http.MethodPost,
		"/bot-bindings/confirm",
		`{"token":"`+createResp.Payload.Data.Token+`"}`,
	)
	if otherResp.Code != http.StatusNotFound {
		t.Fatalf("other user confirm status = %d, want %d; body=%s", otherResp.Code, http.StatusNotFound, otherResp.Body)
	}
}

type botBindingHandlerTestEnv struct {
	handler *BotHandler
	ownerID uuid.UUID
	botID   uuid.UUID
}

func newBotBindingHandlerTestEnv(t *testing.T) botBindingHandlerTestEnv {
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

	botService := service.NewBotService(
		repository.NewBotRepository(db),
		repository.NewBotKeyRepository(db),
		repository.NewBotBindingTokenRepository(db),
		repository.NewAuditLogRepository(db),
	)
	return botBindingHandlerTestEnv{
		handler: NewBotHandler(botService),
		ownerID: ownerID,
		botID:   botID,
	}
}

func (env botBindingHandlerTestEnv) routerForUser(userID uuid.UUID) *gin.Engine {
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("userID", userID)
		c.Next()
	})
	router.POST("/bots/:id/bindings", env.handler.CreateBinding)
	router.GET("/bot-bindings/preview", env.handler.PreviewBinding)
	router.POST("/bot-bindings/confirm", env.handler.ConfirmBinding)
	return router
}

type botBindingAPIResponse[T any] struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    T      `json:"data"`
}

type botBindingHTTPResponse[T any] struct {
	Code    int
	Body    string
	Payload botBindingAPIResponse[T]
}

func doBotBindingRequest[T any](t *testing.T, router *gin.Engine, method string, path string, body string) botBindingHTTPResponse[T] {
	t.Helper()
	var reqBody *bytes.Reader
	if body == "" {
		reqBody = bytes.NewReader(nil)
	} else {
		reqBody = bytes.NewReader([]byte(body))
	}
	req := httptest.NewRequest(method, path, reqBody)
	req.Host = "api.example.test"
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	var payload botBindingAPIResponse[T]
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response %s: %v", recorder.Body.String(), err)
	}
	return botBindingHTTPResponse[T]{
		Code:    recorder.Code,
		Body:    recorder.Body.String(),
		Payload: payload,
	}
}
