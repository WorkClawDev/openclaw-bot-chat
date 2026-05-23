package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/handler"
)

func TestSetupRoutesRegistersBotRuntimeImageImport(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()

	setupRoutes(
		router,
		&handler.AuthHandler{},
		&handler.BotHandler{},
		&handler.MessageHandler{},
		&handler.RealtimeHandler{},
		&handler.AssetHandler{},
		&handler.BotRuntimeHandler{},
		&handler.GroupHandler{},
		nil,
		nil,
	)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/bot-runtime/assets/image/import", nil)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code == http.StatusNotFound {
		t.Fatalf("expected bot runtime import route to be registered, got %d", recorder.Code)
	}
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthenticated request to return 401, got %d", recorder.Code)
	}
}
