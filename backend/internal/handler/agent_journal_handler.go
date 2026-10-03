package handler

import (
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	response "github.com/openclaw-bot-chat/backend/pkg/response"
)

type AgentJournalHandler struct {
	repo *repository.AgentJournalRepository
}

func NewAgentJournalHandler(repo *repository.AgentJournalRepository) *AgentJournalHandler {
	return &AgentJournalHandler{repo: repo}
}
func (h *AgentJournalHandler) Register(r *gin.RouterGroup, runs *AgentRunHandler) {
	r.POST("/inbox", h.Accept)
	r.GET("/inbox/pending", h.Pending)
	r.POST("/inbox/:message/finish", runs.Fence(h.Finish))
	r.POST("/inbox/:message/delivered", h.Delivered)
	r.GET("/context/:scope", h.Context)
	r.PUT("/context/:scope", runs.Fence(h.SaveContext))
	r.POST("/tool-calls/prepare", runs.Fence(h.PrepareTool))
	r.POST("/tool-calls/complete", runs.Fence(h.CompleteTool))
}
func validJournalData(data model.JSONMap) bool {
	raw, err := json.Marshal(data)
	return err == nil && len(raw) <= 2*1024*1024
}
func (h *AgentJournalHandler) Accept(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var req struct {
		MessageID string        `json:"message_id"`
		Message   model.JSONMap `json:"message"`
	}
	if c.ShouldBindJSON(&req) != nil || req.MessageID == "" || len(req.MessageID) > 128 || !validJournalData(req.Message) {
		response.BadRequest(c, "invalid inbox message")
		return
	}
	row, err := h.repo.Accept(c.Request.Context(), bot, req.MessageID, req.Message)
	if err != nil {
		response.InternalError(c, "inbox persistence failed")
		return
	}
	response.Success(c, row)
}
func (h *AgentJournalHandler) Pending(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	rows, err := h.repo.Pending(c.Request.Context(), bot)
	if err != nil {
		response.InternalError(c, "inbox lookup failed")
		return
	}
	response.Success(c, rows)
}
func (h *AgentJournalHandler) Finish(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var req struct {
		Status   string        `json:"status"`
		Response model.JSONMap `json:"response"`
	}
	if c.ShouldBindJSON(&req) != nil || !validJournalData(req.Response) {
		response.BadRequest(c, "invalid response")
		return
	}
	if h.repo.Finish(c.Request.Context(), bot, c.Param("message"), req.Status, req.Response) != nil {
		response.BadRequest(c, "inbox update failed")
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentJournalHandler) Delivered(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	if h.repo.Delivered(c.Request.Context(), bot, c.Param("message")) != nil {
		response.InternalError(c, "delivery update failed")
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentJournalHandler) Context(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	data, err := h.repo.Context(c.Request.Context(), bot, c.Param("scope"))
	if err != nil {
		response.InternalError(c, "context lookup failed")
		return
	}
	response.Success(c, data)
}
func (h *AgentJournalHandler) SaveContext(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var data model.JSONMap
	if c.ShouldBindJSON(&data) != nil || !validJournalData(data) || len(c.Param("scope")) > 128 {
		response.BadRequest(c, "invalid context")
		return
	}
	if h.repo.SaveContext(c.Request.Context(), bot, c.Param("scope"), data) != nil {
		response.InternalError(c, "context persistence failed")
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentJournalHandler) PrepareTool(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var req struct {
		RunID      string `json:"run_id"`
		Key        string `json:"key"`
		Tool       string `json:"tool"`
		Idempotent bool   `json:"idempotent"`
	}
	if c.ShouldBindJSON(&req) != nil || req.RunID == "" || req.Key == "" || len(req.RunID) > 128 || len(req.Key) > 128 {
		response.BadRequest(c, "invalid tool intent")
		return
	}
	row, err := h.repo.PrepareTool(c.Request.Context(), bot, req.RunID, req.Key, req.Tool, req.Idempotent)
	if err != nil {
		response.InternalError(c, "tool intent persistence failed")
		return
	}
	response.Success(c, row)
}
func (h *AgentJournalHandler) CompleteTool(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var req struct {
		RunID  string        `json:"run_id"`
		Key    string        `json:"key"`
		Result model.JSONMap `json:"result"`
	}
	if c.ShouldBindJSON(&req) != nil || !validJournalData(req.Result) {
		response.BadRequest(c, "invalid tool result")
		return
	}
	if h.repo.CompleteTool(c.Request.Context(), bot, req.RunID, req.Key, req.Result) != nil {
		response.InternalError(c, "tool result persistence failed")
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
