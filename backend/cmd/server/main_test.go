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
		&handler.DocumentHandler{},
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

func TestSetupRoutesRegistersBotRuntimeTaskCreate(t *testing.T) {
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
		&handler.DocumentHandler{},
		nil,
		nil,
	)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/bot-runtime/tasks", nil)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code == http.StatusNotFound {
		t.Fatalf("expected bot runtime task create route to be registered, got %d", recorder.Code)
	}
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthenticated request to return 401, got %d", recorder.Code)
	}
}

func TestSetupRoutesRegistersTaskReviewLoopRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	t.Setenv("OPENCLAW_DOCUMENTS_ENABLED", "")
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
		&handler.DocumentHandler{},
		nil,
		nil,
	)

	taskID := "00000000-0000-4000-8000-000000000001"
	routes := []struct {
		method string
		path   string
	}{
		{http.MethodPost, "/api/v1/tasks/" + taskID + "/dispatch"},
		{http.MethodPost, "/api/v1/tasks/" + taskID + "/accept"},
		{http.MethodPost, "/api/v1/tasks/" + taskID + "/reject"},
		{http.MethodPost, "/api/v1/tasks/" + taskID + "/retry"},
		{http.MethodPost, "/api/v1/tasks/" + taskID + "/cancel"},
		{http.MethodGet, "/api/v1/bot-runtime/tasks/queue"},
		{http.MethodPost, "/api/v1/bot-runtime/tasks/" + taskID + "/result"},
		{http.MethodPost, "/api/v1/bot-runtime/documents"},
		{http.MethodPut, "/api/v1/bot-runtime/documents/" + taskID},
		{http.MethodGet, "/api/v1/documents"},
		{http.MethodPost, "/api/v1/documents"},
		{http.MethodGet, "/api/v1/documents/" + taskID},
		{http.MethodPut, "/api/v1/documents/" + taskID},
		{http.MethodDelete, "/api/v1/documents/" + taskID},
	}
	for _, route := range routes {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			req := httptest.NewRequest(route.method, route.path, nil)
			recorder := httptest.NewRecorder()
			router.ServeHTTP(recorder, req)

			if recorder.Code == http.StatusNotFound {
				t.Fatalf("expected route to be registered, got %d", recorder.Code)
			}
			if recorder.Code != http.StatusUnauthorized {
				t.Fatalf("expected unauthenticated request to return 401, got %d", recorder.Code)
			}
		})
	}
}

func TestSetupRoutesCanDisableDocuments(t *testing.T) {
	gin.SetMode(gin.TestMode)
	t.Setenv("OPENCLAW_DOCUMENTS_ENABLED", "false")
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
		&handler.DocumentHandler{},
		nil,
		nil,
	)

	routes := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/documents"},
		{http.MethodPost, "/api/v1/documents"},
		{http.MethodPost, "/api/v1/bot-runtime/documents"},
		{http.MethodPut, "/api/v1/bot-runtime/documents/00000000-0000-4000-8000-000000000001"},
	}

	for _, route := range routes {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			req := httptest.NewRequest(route.method, route.path, nil)
			recorder := httptest.NewRecorder()
			router.ServeHTTP(recorder, req)

			if recorder.Code != http.StatusNotFound {
				t.Fatalf("expected disabled documents route to return 404, got %d", recorder.Code)
			}
		})
	}
}
