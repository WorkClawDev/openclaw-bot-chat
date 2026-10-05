package middleware

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
)

type accountFixture struct{ user *model.User }

func (f *accountFixture) GetByID(context.Context, uuid.UUID) (*model.User, error) { return f.user, nil }

func TestAccountAccessUsesCurrentRoleAndStatus(t *testing.T) {
	gin.SetMode(gin.TestMode)
	user := &model.User{ID: uuid.New(), Role: model.UserRoleAdmin, Status: model.UserStatusActive}
	lookup := &accountFixture{user: user}
	router := gin.New()
	router.Use(func(c *gin.Context) { c.Set("userID", user.ID); c.Set("tokenVersion", int64(0)) }, ActiveAccount(lookup))
	router.GET("/private", func(c *gin.Context) { c.Status(204) })
	router.GET("/admin", RequireAdmin(), func(c *gin.Context) { c.Status(204) })
	check := func(path string, want int) {
		t.Helper()
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != want {
			t.Fatalf("%s: got %d, want %d", path, response.Code, want)
		}
	}
	check("/admin", 204)
	user.Role = model.UserRoleUser
	check("/admin", 403)
	check("/private", 204)
	for _, status := range []model.UserStatus{model.UserStatusInactive, model.UserStatusBanned} {
		user.Status = status
		check("/private", 401)
		check("/admin", 401)
	}
	user.Status = model.UserStatusActive
	user.IsDeleted = true
	check("/private", 401)
	lookup.user = nil
	check("/private", 401)
}

func TestReactivationRejectsOldSignedAccessTokens(t *testing.T) {
	gin.SetMode(gin.TestMode)
	user := &model.User{ID: uuid.New(), Username: "member", Status: model.UserStatusActive}
	manager := jwt.NewManager(jwt.Config{Secret: "regression-only-secret", AccessTokenTTL: 3600, RefreshTokenTTL: 7200})
	old, err := manager.GenerateAccessToken(user.ID, user.Username, 0)
	if err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.Use(JWTAuth(manager), ActiveAccount(&accountFixture{user: user}))
	router.GET("/private", func(c *gin.Context) { c.Status(204) })
	check := func(token string, want int) {
		t.Helper()
		request := httptest.NewRequest("GET", "/private", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		result := httptest.NewRecorder()
		router.ServeHTTP(result, request)
		if result.Code != want {
			t.Fatalf("got %d, want %d", result.Code, want)
		}
	}
	check(old, 204)
	user.Status, user.TokenVersion = model.UserStatusBanned, 1
	check(old, 401)
	user.Status, user.TokenVersion = model.UserStatusActive, 2
	check(old, 401)
	fresh, err := manager.GenerateAccessToken(user.ID, user.Username, user.TokenVersion)
	if err != nil {
		t.Fatal(err)
	}
	check(fresh, 204)
}
