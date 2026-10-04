package middleware

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

type accountFixture struct{ user *model.User }

func (f *accountFixture) GetByID(context.Context, uuid.UUID) (*model.User, error) { return f.user, nil }

func TestAccountAccessUsesCurrentRoleAndStatus(t *testing.T) {
	gin.SetMode(gin.TestMode)
	user := &model.User{ID: uuid.New(), Role: model.UserRoleAdmin, Status: model.UserStatusActive}
	lookup := &accountFixture{user: user}
	router := gin.New()
	router.Use(func(c *gin.Context) { c.Set("userID", user.ID) }, ActiveAccount(lookup))
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
