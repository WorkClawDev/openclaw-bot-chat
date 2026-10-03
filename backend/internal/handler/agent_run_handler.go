package handler

import (
	"context"
	"errors"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	response "github.com/openclaw-bot-chat/backend/pkg/response"
	"strconv"
	"strings"
	"time"
)

type AgentRunHandler struct {
	Repo *repository.AgentRunRepository
}

func NewAgentRunHandler(repo *repository.AgentRunRepository) *AgentRunHandler {
	return &AgentRunHandler{Repo: repo}
}
func (h *AgentRunHandler) RegisterRuntime(r *gin.RouterGroup) {
	r.POST("/runs", h.Create)
	r.GET("/runs", h.ListRuntime)
	r.GET("/runs/:id", h.GetRuntime)
	r.POST("/runs/:id/claim", h.Claim)
	r.POST("/runs/:id/heartbeat", h.Heartbeat)
	r.POST("/runs/:id/transition", h.Transition)
	r.POST("/runs/:id/events", h.Event)
}
func (h *AgentRunHandler) RegisterUser(r *gin.RouterGroup) {
	r.GET("/runs", h.List)
	r.GET("/runs/:id/events", h.Events)
	r.POST("/runs/:id/:action", h.UserAction)
}
func (h *AgentRunHandler) Create(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var req struct {
		TriggerKey   string        `json:"trigger_key"`
		Conversation string        `json:"conversation"`
		TaskID       *uuid.UUID    `json:"task_id"`
		Input        model.JSONMap `json:"input"`
	}
	if c.ShouldBindJSON(&req) != nil || req.TriggerKey == "" || len(req.TriggerKey) > 256 || !validJournalData(req.Input) {
		response.BadRequest(c, "invalid run")
		return
	}
	row, err := h.Repo.Create(c.Request.Context(), bot, req.TriggerKey, req.Conversation, req.TaskID, req.Input)
	if err != nil {
		response.BadRequest(c, "run cannot be created for this task")
		return
	}
	response.Success(c, row)
}
func runID(c *gin.Context) (uuid.UUID, bool) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		response.BadRequest(c, "invalid run id")
		return uuid.Nil, false
	}
	return id, true
}

type runWorkerRequest struct {
	Outbox   *repository.AgentRunOutbox `json:"outbox"`
	WorkerID string                     `json:"worker_id"`
	Fence    int64                      `json:"fence"`
	Status   string                     `json:"status"`
	Result   model.JSONMap              `json:"result"`
	Note     string                     `json:"note"`
	Type     string                     `json:"type"`
	Data     model.JSONMap              `json:"data"`
}

func bindRunWorker(c *gin.Context) (runWorkerRequest, bool) {
	var req runWorkerRequest
	if c.ShouldBindJSON(&req) != nil || req.WorkerID == "" || len(req.WorkerID) > 128 {
		response.BadRequest(c, "invalid worker")
		return req, false
	}
	return req, true
}
func writeRunError(c *gin.Context, err error) {
	if errors.Is(err, repository.ErrAgentLease) || errors.Is(err, repository.ErrAgentState) {
		c.JSON(409, gin.H{"message": err.Error()})
	} else {
		response.BadRequest(c, "run operation failed")
	}
}
func (h *AgentRunHandler) Claim(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	req, ok := bindRunWorker(c)
	if !ok {
		return
	}
	row, err := h.Repo.Claim(c.Request.Context(), bot, id, req.WorkerID, time.Now().UnixMilli())
	if err != nil {
		writeRunError(c, err)
		return
	}
	response.Success(c, row)
}
func (h *AgentRunHandler) Heartbeat(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	req, ok := bindRunWorker(c)
	if !ok {
		return
	}
	row, err := h.Repo.Heartbeat(c.Request.Context(), bot, id, req.WorkerID, req.Fence)
	if err != nil {
		writeRunError(c, err)
		return
	}
	response.Success(c, row)
}
func (h *AgentRunHandler) Transition(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	req, ok := bindRunWorker(c)
	if !ok {
		return
	}
	if !validJournalData(req.Result) {
		response.BadRequest(c, "result too large")
		return
	}
	if err := h.Repo.Transition(c.Request.Context(), bot, id, req.WorkerID, req.Fence, req.Status, req.Result, req.Note, req.Outbox); err != nil {
		writeRunError(c, err)
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentRunHandler) Event(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	req, ok := bindRunWorker(c)
	if !ok {
		return
	}
	if len(req.Type) > 64 || !validJournalData(req.Data) {
		response.BadRequest(c, "invalid event")
		return
	}
	if err := h.Repo.Event(c.Request.Context(), bot, id, req.WorkerID, req.Fence, req.Type, req.Data); err != nil {
		writeRunError(c, err)
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentRunHandler) ListRuntime(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	rows, err := h.Repo.List(c.Request.Context(), bot.OwnerID, &bot.ID)
	if err != nil {
		response.InternalError(c, "run list failed")
		return
	}
	response.Success(c, rows)
}
func (h *AgentRunHandler) GetRuntime(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	row, err := h.Repo.Get(c.Request.Context(), bot.OwnerID, &bot.ID, id)
	if err != nil {
		response.NotFound(c, "run not found")
		return
	}
	response.Success(c, row)
}
func (h *AgentRunHandler) List(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	rows, err := h.Repo.List(c.Request.Context(), owner, nil)
	if err != nil {
		response.InternalError(c, "run list failed")
		return
	}
	response.Success(c, rows)
}
func (h *AgentRunHandler) Events(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	after, _ := strconv.ParseInt(c.DefaultQuery("after_seq", "0"), 10, 64)
	rows, err := h.Repo.Events(c.Request.Context(), owner, id, after)
	if err != nil {
		response.NotFound(c, "run not found")
		return
	}
	response.Success(c, rows)
}
func (h *AgentRunHandler) UserAction(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	var req struct {
		Input string `json:"input"`
	}
	if c.ShouldBindJSON(&req) != nil || len(req.Input) > 32000 {
		response.BadRequest(c, "invalid input")
		return
	}
	if err := h.Repo.UserAction(c.Request.Context(), owner, id, c.Param("action"), req.Input); err != nil {
		writeRunError(c, err)
		return
	}
	response.Success(c, gin.H{"status": "saved"})
}
func (h *AgentRunHandler) Fence(next gin.HandlerFunc) gin.HandlerFunc {
	return func(c *gin.Context) {
		bot, _ := middleware.GetBot(c)
		id, err := uuid.Parse(c.GetHeader("X-Agent-Run"))
		if err != nil {
			response.BadRequest(c, "execution lease required")
			return
		}
		fence, err := strconv.ParseInt(c.GetHeader("X-Agent-Fence"), 10, 64)
		if err != nil {
			response.BadRequest(c, "execution fence required")
			return
		}
		err = h.Repo.Fenced(c.Request.Context(), bot, id, c.GetHeader("X-Agent-Worker"), fence, strings.Contains(c.Request.URL.Path, "/context/") || strings.HasSuffix(c.Request.URL.Path, "/finish"), func(ctx context.Context) error {
			c.Request = c.Request.WithContext(ctx)
			next(c)
			if c.Writer.Status() >= 400 {
				return errors.New("fenced operation rejected")
			}
			return nil
		})
		if err != nil && !c.Writer.Written() {
			writeRunError(c, err)
		}
	}
}
