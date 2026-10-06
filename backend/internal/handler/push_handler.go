package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/response"
)

type PushHandler struct {
	Repo    *repository.PushRepository
	Enabled bool
}

func (h *PushHandler) Register(r *gin.RouterGroup) {
	r.GET("/push/status", func(c *gin.Context) { response.Success(c, gin.H{"available": h.Enabled}) })
	r.PUT("/push/devices/:id", h.Save)
	r.DELETE("/push/devices/:id", h.Disable)
}

func (h *PushHandler) Save(c *gin.Context) {
	owner, ok := middleware.GetUserID(c)
	if !ok {
		response.Unauthorized(c, "authentication required")
		return
	}
	if !h.Enabled {
		c.JSON(503, gin.H{"code": 503, "message": "Push notifications are not configured on this server"})
		return
	}
	id, err := uuid.Parse(c.Param("id"))
	if err != nil || id == uuid.Nil {
		response.BadRequest(c, "invalid installation ID")
		return
	}
	var input struct {
		Token       string `json:"token"`
		Environment string `json:"environment"`
		Language    string `json:"language"`
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 4096)
	if c.ShouldBindJSON(&input) != nil {
		response.BadRequest(c, "invalid push registration")
		return
	}
	err = h.Repo.Register(c.Request.Context(), model.PushDevice{ID: id, UserID: owner, Token: input.Token, Environment: input.Environment, Language: input.Language, Enabled: true}, time.Now().UTC())
	if errors.Is(err, repository.ErrInvalidPushDevice) {
		response.BadRequest(c, "invalid push registration")
		return
	}
	if err != nil {
		response.InternalError(c, "push registration unavailable")
		return
	}
	response.Success(c, gin.H{"registered": true})
}

func (h *PushHandler) Disable(c *gin.Context) {
	owner, ok := middleware.GetUserID(c)
	if !ok {
		response.Unauthorized(c, "authentication required")
		return
	}
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid installation ID")
		return
	}
	if err := h.Repo.Disable(c.Request.Context(), owner, id, time.Now().UTC()); err != nil {
		response.InternalError(c, "push registration unavailable")
		return
	}
	response.Success(c, gin.H{"registered": false})
}
