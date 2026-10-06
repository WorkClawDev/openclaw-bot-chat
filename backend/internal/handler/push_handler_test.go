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
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func TestPushRegistrationRequiresJWTAndDoesNotExposeDeviceToken(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := db.DB()
	t.Cleanup(func() { _ = raw.Close() })
	if err := db.AutoMigrate(&model.PushDevice{}); err != nil {
		t.Fatal(err)
	}
	manager := jwt.NewManager(jwt.Config{Secret: "test-only-not-a-production-secret", AccessTokenTTL: 300, Issuer: "tests"})
	owner, other, device := uuid.New(), uuid.New(), uuid.New()
	ownerToken, _ := manager.GenerateAccessToken(owner, "owner")
	otherToken, _ := manager.GenerateAccessToken(other, "other")
	router := gin.New()
	group := router.Group("/api/v1")
	group.Use(middleware.JWTAuth(manager))
	handler := &PushHandler{Repo: repository.NewPushRepository(db), Enabled: true}
	handler.Register(group)
	request := func(method, path, token string, body any) *httptest.ResponseRecorder {
		data, _ := json.Marshal(body)
		r := httptest.NewRequest(method, path, bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	path := "/api/v1/push/devices/" + device.String()
	body := map[string]any{"token": "abcdef0123456789", "environment": "sandbox", "language": "zh", "user_id": other.String()}
	if w := request(http.MethodPut, path, "", body); w.Code != 401 {
		t.Fatalf("unauthenticated status %d", w.Code)
	}
	if w := request(http.MethodPut, path, ownerToken, body); w.Code != 200 || strings.Contains(w.Body.String(), body["token"].(string)) {
		t.Fatal("registration failed or exposed token")
	}
	var saved model.PushDevice
	if err := db.First(&saved, "id = ?", device).Error; err != nil || saved.UserID != owner {
		t.Fatal("request overrode JWT owner", err)
	}
	if w := request(http.MethodDelete, path, otherToken, nil); w.Code != 200 {
		t.Fatal("idempotent disable failed")
	}
	db.First(&saved, "id = ?", device)
	if !saved.Enabled {
		t.Fatal("foreign user disabled installation")
	}
	if w := request(http.MethodDelete, path, ownerToken, nil); w.Code != 200 {
		t.Fatal("owner disable failed")
	}
	db.First(&saved, "id = ?", device)
	if saved.Enabled {
		t.Fatal("owner disable did not persist")
	}
	body["token"] = "not-hex"
	if w := request(http.MethodPut, path, ownerToken, body); w.Code != 400 {
		t.Fatal("invalid device accepted")
	}
	handler.Enabled = false
	if w := request(http.MethodPut, path, ownerToken, body); w.Code != 503 {
		t.Fatal("unconfigured APNs reported success")
	}
	if w := request(http.MethodGet, "/api/v1/push/status", ownerToken, nil); w.Code != 200 || !strings.Contains(w.Body.String(), `"available":false`) {
		t.Fatal("availability not exposed")
	}
}
