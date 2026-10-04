package middleware

import (
	"context"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/pkg/response"
)

type UserLookup interface {
	GetByID(context.Context, uuid.UUID) (*model.User, error)
}

// Read account state on every request. JWT claims must not preserve a revoked
// role or let a disabled account continue using a previously issued token.
func ActiveAccount(users UserLookup) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := GetUserID(c)
		if !ok || users == nil {
			response.Unauthorized(c, "active account required")
			c.Abort()
			return
		}
		user, err := users.GetByID(c.Request.Context(), id)
		if err != nil || !user.IsActive() {
			response.Unauthorized(c, "active account required")
			c.Abort()
			return
		}
		c.Set("userRole", user.Role)
		c.Next()
	}
}

func RequireAdmin() gin.HandlerFunc {
	return func(c *gin.Context) {
		role, ok := c.Get("userRole")
		if !ok || role != model.UserRoleAdmin {
			response.Forbidden(c, "administrator role required")
			c.Abort()
			return
		}
		c.Next()
	}
}
