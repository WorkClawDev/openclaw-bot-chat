package handler

import (
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/service"
	response "github.com/openclaw-bot-chat/backend/pkg/response"
)

type AgentApprovalHandler struct{ service *service.AgentApprovalService }

func NewAgentApprovalHandler(s *service.AgentApprovalService) *AgentApprovalHandler {
	return &AgentApprovalHandler{service: s}
}
func (h *AgentApprovalHandler) Request(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		response.Unauthorized(c, "unauthorized")
		return
	}
	var req service.AgentApprovalRequest
	if c.ShouldBindJSON(&req) != nil {
		response.BadRequest(c, "invalid approval")
		return
	}
	row, err := h.service.Request(c.Request.Context(), bot, req)
	if err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	response.Success(c, row)
}
func (h *AgentApprovalHandler) List(c *gin.Context) {
	owner, ok := middleware.GetUserID(c)
	if !ok {
		response.Unauthorized(c, "unauthorized")
		return
	}
	rows, err := h.service.List(c.Request.Context(), owner)
	if err != nil {
		response.InternalError(c, "approval lookup failed")
		return
	}
	response.Success(c, rows)
}
func (h *AgentApprovalHandler) Get(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		response.Unauthorized(c, "unauthorized")
		return
	}
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid id")
		return
	}
	row, err := h.service.Get(c.Request.Context(), bot, id)
	if err != nil {
		response.NotFound(c, "approval not found")
		return
	}
	response.Success(c, row)
}
func (h *AgentApprovalHandler) Decide(c *gin.Context) {
	owner, ok := middleware.GetUserID(c)
	if !ok {
		response.Unauthorized(c, "unauthorized")
		return
	}
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid id")
		return
	}
	var req struct {
		Approved *bool `json:"approved"`
	}
	if c.ShouldBindJSON(&req) != nil || req.Approved == nil {
		response.BadRequest(c, "decision is required")
		return
	}
	if h.service.Decide(c.Request.Context(), owner, id, *req.Approved) != nil {
		response.NotFound(c, "approval expired, decided, or not owned")
		return
	}
	response.Success(c, gin.H{"status": "recorded"})
}
