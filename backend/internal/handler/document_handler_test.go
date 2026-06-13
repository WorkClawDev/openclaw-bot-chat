package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestDocumentHandlerCRUDArchiveAndResponseShape(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newDocumentHandlerTestEnv(t)
	router := env.routerForUser(env.ownerID)

	createResp := doDocumentHandlerRequest[responsedto.DocumentResponse](t, router, http.MethodPost, "/documents", `{
		"title": "AI 编程学习路线",
		"body": "# AI 编程学习路线\n\n第一周：工具链。",
		"summary": "路线摘要"
	}`)
	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body=%s", createResp.Code, http.StatusCreated, createResp.Body)
	}
	created := createResp.Payload.Data
	if created.ID == uuid.Nil {
		t.Fatal("create response did not include document id")
	}
	if created.URL != "/documents/"+created.ID.String() {
		t.Fatalf("create response url = %q, want stable document url", created.URL)
	}
	if created.Body == "" {
		t.Fatal("create response should include body for immediate editor hydration")
	}

	listResp := doDocumentHandlerRequest[[]responsedto.DocumentResponse](t, router, http.MethodGet, "/documents", "")
	if listResp.Code != http.StatusOK {
		t.Fatalf("list status = %d, want %d; body=%s", listResp.Code, http.StatusOK, listResp.Body)
	}
	if len(listResp.Payload.Data) != 1 || listResp.Payload.Data[0].ID != created.ID {
		t.Fatalf("list data = %#v, want created document", listResp.Payload.Data)
	}
	if listResp.Payload.Data[0].Body != "" {
		t.Fatalf("list response leaked full body = %q", listResp.Payload.Data[0].Body)
	}

	getResp := doDocumentHandlerRequest[responsedto.DocumentResponse](t, router, http.MethodGet, "/documents/"+created.ID.String(), "")
	if getResp.Code != http.StatusOK {
		t.Fatalf("get status = %d, want %d; body=%s", getResp.Code, http.StatusOK, getResp.Body)
	}
	if getResp.Payload.Data.Body != created.Body {
		t.Fatalf("get body = %q, want persisted body %q", getResp.Payload.Data.Body, created.Body)
	}

	updateResp := doDocumentHandlerRequest[responsedto.DocumentResponse](t, router, http.MethodPut, "/documents/"+created.ID.String(), `{
		"title": "AI Agent 学习路线",
		"body": "# AI Agent 学习路线\n\n加入部署章节。"
	}`)
	if updateResp.Code != http.StatusOK {
		t.Fatalf("update status = %d, want %d; body=%s", updateResp.Code, http.StatusOK, updateResp.Body)
	}
	if updateResp.Payload.Data.Title != "AI Agent 学习路线" || !strings.Contains(updateResp.Payload.Data.Body, "部署章节") {
		t.Fatalf("update response = %#v, want edited title and body", updateResp.Payload.Data)
	}

	archiveResp := doDocumentHandlerRequest[map[string]string](t, router, http.MethodDelete, "/documents/"+created.ID.String(), "")
	if archiveResp.Code != http.StatusOK {
		t.Fatalf("archive status = %d, want %d; body=%s", archiveResp.Code, http.StatusOK, archiveResp.Body)
	}

	getArchivedResp := doDocumentHandlerRequest[map[string]any](t, router, http.MethodGet, "/documents/"+created.ID.String(), "")
	if getArchivedResp.Code != http.StatusNotFound {
		t.Fatalf("get archived status = %d, want %d; body=%s", getArchivedResp.Code, http.StatusNotFound, getArchivedResp.Body)
	}
	listArchivedResp := doDocumentHandlerRequest[[]responsedto.DocumentResponse](t, router, http.MethodGet, "/documents", "")
	if listArchivedResp.Code != http.StatusOK {
		t.Fatalf("list after archive status = %d, want %d; body=%s", listArchivedResp.Code, http.StatusOK, listArchivedResp.Body)
	}
	if len(listArchivedResp.Payload.Data) != 0 {
		t.Fatalf("list after archive = %#v, want empty", listArchivedResp.Payload.Data)
	}
}

func TestDocumentHandlerOwnerIsolation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newDocumentHandlerTestEnv(t)
	ownerRouter := env.routerForUser(env.ownerID)
	otherRouter := env.routerForUser(uuid.New())

	createResp := doDocumentHandlerRequest[responsedto.DocumentResponse](t, ownerRouter, http.MethodPost, "/documents", `{
		"title": "Private Plan",
		"body": "Owner only."
	}`)
	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body=%s", createResp.Code, http.StatusCreated, createResp.Body)
	}
	documentID := createResp.Payload.Data.ID.String()

	otherGet := doDocumentHandlerRequest[map[string]any](t, otherRouter, http.MethodGet, "/documents/"+documentID, "")
	if otherGet.Code != http.StatusNotFound {
		t.Fatalf("other get status = %d, want %d; body=%s", otherGet.Code, http.StatusNotFound, otherGet.Body)
	}
	otherUpdate := doDocumentHandlerRequest[map[string]any](t, otherRouter, http.MethodPut, "/documents/"+documentID, `{"title":"Stolen"}`)
	if otherUpdate.Code != http.StatusNotFound {
		t.Fatalf("other update status = %d, want %d; body=%s", otherUpdate.Code, http.StatusNotFound, otherUpdate.Body)
	}
	otherArchive := doDocumentHandlerRequest[map[string]any](t, otherRouter, http.MethodDelete, "/documents/"+documentID, "")
	if otherArchive.Code != http.StatusNotFound {
		t.Fatalf("other archive status = %d, want %d; body=%s", otherArchive.Code, http.StatusNotFound, otherArchive.Body)
	}
	otherList := doDocumentHandlerRequest[[]responsedto.DocumentResponse](t, otherRouter, http.MethodGet, "/documents", "")
	if otherList.Code != http.StatusOK || len(otherList.Payload.Data) != 0 {
		t.Fatalf("other list status=%d data=%#v, want 200 empty", otherList.Code, otherList.Payload.Data)
	}

	ownerGet := doDocumentHandlerRequest[responsedto.DocumentResponse](t, ownerRouter, http.MethodGet, "/documents/"+documentID, "")
	if ownerGet.Code != http.StatusOK {
		t.Fatalf("owner get after blocked other actions status = %d, want %d; body=%s", ownerGet.Code, http.StatusOK, ownerGet.Body)
	}
}

func TestDocumentHandlerRejectsUnauthenticatedInvalidIDAndOversizedBody(t *testing.T) {
	gin.SetMode(gin.TestMode)
	env := newDocumentHandlerTestEnv(t)
	authenticatedRouter := env.routerForUser(env.ownerID)
	unauthenticatedRouter := env.routerWithoutUser()

	unauthResp := doDocumentHandlerRequest[map[string]any](t, unauthenticatedRouter, http.MethodGet, "/documents", "")
	if unauthResp.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want %d; body=%s", unauthResp.Code, http.StatusUnauthorized, unauthResp.Body)
	}

	invalidIDResp := doDocumentHandlerRequest[map[string]any](t, authenticatedRouter, http.MethodGet, "/documents/not-a-uuid", "")
	if invalidIDResp.Code != http.StatusBadRequest {
		t.Fatalf("invalid id status = %d, want %d; body=%s", invalidIDResp.Code, http.StatusBadRequest, invalidIDResp.Body)
	}

	oversizedBody := strings.Repeat("x", 2*1024*1024+1)
	payload, err := json.Marshal(map[string]string{
		"title": "Too Large",
		"body":  oversizedBody,
	})
	if err != nil {
		t.Fatalf("marshal oversized payload: %v", err)
	}
	oversizedResp := doDocumentHandlerRequest[map[string]any](t, authenticatedRouter, http.MethodPost, "/documents", string(payload))
	if oversizedResp.Code != http.StatusBadRequest {
		t.Fatalf("oversized body status = %d, want %d; body=%s", oversizedResp.Code, http.StatusBadRequest, oversizedResp.Body)
	}
}

type documentHandlerTestEnv struct {
	handler *DocumentHandler
	ownerID uuid.UUID
}

func newDocumentHandlerTestEnv(t *testing.T) documentHandlerTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE documents (
			id text PRIMARY KEY,
			owner_id text NOT NULL,
			title text NOT NULL,
			summary text,
			body text,
			document_type text NOT NULL DEFAULT 'markdown',
			source text NOT NULL DEFAULT 'user',
			status text NOT NULL DEFAULT 'active',
			source_bot_id text,
			source_conversation_id text,
			source_message_id text,
			metadata text,
			created_at datetime,
			updated_at datetime,
			deleted_at datetime
		)
	`).Error; err != nil {
		t.Fatalf("migrate documents: %v", err)
	}
	docService := service.NewDocumentService(repository.NewDocumentRepository(db))
	return documentHandlerTestEnv{
		handler: NewDocumentHandler(docService),
		ownerID: uuid.New(),
	}
}

func (env documentHandlerTestEnv) routerForUser(userID uuid.UUID) *gin.Engine {
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("userID", userID)
		c.Next()
	})
	env.mountRoutes(router)
	return router
}

func (env documentHandlerTestEnv) routerWithoutUser() *gin.Engine {
	router := gin.New()
	env.mountRoutes(router)
	return router
}

func (env documentHandlerTestEnv) mountRoutes(router *gin.Engine) {
	router.GET("/documents", env.handler.List)
	router.POST("/documents", env.handler.Create)
	router.GET("/documents/:id", env.handler.Get)
	router.PUT("/documents/:id", env.handler.Update)
	router.DELETE("/documents/:id", env.handler.Archive)
}

type documentHandlerAPIResponse[T any] struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    T      `json:"data"`
}

type documentHandlerHTTPResponse[T any] struct {
	Code    int
	Body    string
	Payload documentHandlerAPIResponse[T]
}

func doDocumentHandlerRequest[T any](t *testing.T, router *gin.Engine, method, path, body string) documentHandlerHTTPResponse[T] {
	t.Helper()
	var requestBody *bytes.Reader
	if body == "" {
		requestBody = bytes.NewReader(nil)
	} else {
		requestBody = bytes.NewReader([]byte(body))
	}
	req := httptest.NewRequest(method, path, requestBody)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	result := documentHandlerHTTPResponse[T]{
		Code: recorder.Code,
		Body: recorder.Body.String(),
	}
	if recorder.Body.Len() > 0 {
		if err := json.Unmarshal(recorder.Body.Bytes(), &result.Payload); err != nil {
			t.Fatalf("decode response body %q: %v", recorder.Body.String(), err)
		}
	}
	return result
}
