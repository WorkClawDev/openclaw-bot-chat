package handler

import (
	"errors"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	dto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/response"
	"gorm.io/gorm"
)

type UserAdminHandler struct{ Users *repository.UserRepository }

func (h *UserAdminHandler) Register(routes *gin.RouterGroup) {
	admin := routes.Group("/admin", middleware.RequireAdmin())
	admin.GET("/users", h.List)
	admin.PUT("/users/:id/access", h.UpdateAccess)
}

func (h *UserAdminHandler) List(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 100 {
		size = 20
	}
	users, total, err := h.Users.ListAccounts(c.Request.Context(), c.Query("search"), page, size)
	if err != nil {
		response.InternalError(c, "could not load accounts")
		return
	}
	response.Paginated(c, dto.NewUserResponses(users), page, size, total)
}

func (h *UserAdminHandler) UpdateAccess(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid user id")
		return
	}
	var req struct {
		Role   *model.UserRole   `json:"role"`
		Status *model.UserStatus `json:"status"`
	}
	if c.ShouldBindJSON(&req) != nil {
		response.BadRequest(c, "invalid access update")
		return
	}
	actorID, _ := middleware.GetUserID(c)
	user, err := h.Users.UpdateAccountAccess(c.Request.Context(), actorID, id, req.Role, req.Status, c.ClientIP())
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		response.NotFound(c, "user not found")
	case errors.Is(err, repository.ErrInvalidAccountAccess):
		response.BadRequest(c, err.Error())
	case errors.Is(err, repository.ErrLastAdmin), errors.Is(err, repository.ErrSelfAdminChange):
		response.Conflict(c, err.Error())
	case errors.Is(err, repository.ErrAdminRequired):
		response.Forbidden(c, err.Error())
	case err != nil:
		response.InternalError(c, "could not update account access")
	default:
		response.Success(c, dto.NewUserResponse(user))
	}
}
