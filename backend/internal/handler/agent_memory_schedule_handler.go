package handler

import (
	"context"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	response "github.com/openclaw-bot-chat/backend/pkg/response"
	"time"
)

type AgentMemoryScheduleHandler struct {
	Memory    *repository.AgentMemoryRepository
	Schedules *repository.AgentScheduleRepository
}

func (h *AgentMemoryScheduleHandler) RegisterUser(r *gin.RouterGroup) {
	r.GET("/memories", h.ListMemory)
	r.POST("/memories", h.SaveMemory)
	r.PUT("/memories/:id", h.SaveMemory)
	r.DELETE("/memories/:id", h.DeleteMemory)
	r.GET("/memories/export", h.ListMemory)
	r.GET("/schedules", h.ListSchedules)
	r.POST("/schedules", h.SaveSchedule)
	r.POST("/schedules/:id/:action", h.ScheduleAction)
}
func (h *AgentMemoryScheduleHandler) RegisterRuntime(r *gin.RouterGroup) {
	r.GET("/memories", h.RuntimeMemory)
	r.POST("/memories", h.RuntimeSave)
	r.DELETE("/memories/:id", h.RuntimeDelete)
}
func (h *AgentMemoryScheduleHandler) ListMemory(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	rows, err := h.Memory.List(c.Request.Context(), owner, nil, "")
	if err != nil {
		response.InternalError(c, "memory unavailable")
		return
	}
	response.Success(c, rows)
}
func (h *AgentMemoryScheduleHandler) SaveMemory(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	var row model.AgentMemory
	if c.ShouldBindJSON(&row) != nil {
		response.BadRequest(c, "invalid memory")
		return
	}
	row.ID = uuid.Nil
	if c.Param("id") != "" {
		id, ok := runID(c)
		if !ok {
			return
		}
		row.ID = id
	}
	if err := h.Memory.Save(c.Request.Context(), owner, &row); err != nil {
		response.BadRequest(c, "confirmed memory requires owned bot and valid content")
		return
	}
	response.Success(c, row)
}
func (h *AgentMemoryScheduleHandler) DeleteMemory(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	if err := h.Memory.Delete(c.Request.Context(), owner, id); err != nil {
		response.NotFound(c, "memory not found")
		return
	}
	response.Success(c, gin.H{"status": "deleted"})
}
func (h *AgentMemoryScheduleHandler) RuntimeMemory(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	rows, err := h.Memory.List(c.Request.Context(), bot.OwnerID, &bot.ID, c.Query("scope"))
	if err != nil {
		response.InternalError(c, "memory unavailable")
		return
	}
	revision, err := h.Memory.Revision(c.Request.Context(), bot.ID)
	if err != nil {
		response.InternalError(c, "memory unavailable")
		return
	}
	response.Success(c, gin.H{"records": rows, "revision": revision})
}
func (h *AgentMemoryScheduleHandler) RuntimeSave(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	var row model.AgentMemory
	if c.ShouldBindJSON(&row) != nil {
		response.BadRequest(c, "invalid memory")
		return
	}
	row.ID = uuid.Nil
	row.BotID = bot.ID
	if !row.Confirmed {
		response.BadRequest(c, "explicit confirmation required")
		return
	}
	if err := h.Memory.Save(c.Request.Context(), bot.OwnerID, &row); err != nil {
		response.BadRequest(c, "invalid memory")
		return
	}
	response.Success(c, row)
}
func (h *AgentMemoryScheduleHandler) RuntimeDelete(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	rows, err := h.Memory.List(c.Request.Context(), bot.OwnerID, &bot.ID, "")
	if err != nil {
		response.InternalError(c, "memory unavailable")
		return
	}
	owned := false
	for _, row := range rows {
		if row.ID == id {
			owned = true
		}
	}
	if !owned {
		response.NotFound(c, "memory not found")
		return
	}
	if err = h.Memory.Delete(c.Request.Context(), bot.OwnerID, id); err != nil {
		response.InternalError(c, "delete failed")
		return
	}
	response.Success(c, gin.H{"status": "deleted"})
}
func (h *AgentMemoryScheduleHandler) ListSchedules(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	rows, err := h.Schedules.List(c.Request.Context(), owner)
	if err != nil {
		response.InternalError(c, "schedules unavailable")
		return
	}
	response.Success(c, rows)
}
func (h *AgentMemoryScheduleHandler) SaveSchedule(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	var req struct {
		model.AgentSchedule
		LocalTime string `json:"local_time"`
	}
	if c.ShouldBindJSON(&req) != nil {
		response.BadRequest(c, "invalid schedule")
		return
	}
	if req.LocalTime != "" {
		loc, err := time.LoadLocation(req.Timezone)
		if err != nil {
			response.BadRequest(c, "invalid timezone")
			return
		}
		at, err := time.ParseInLocation("2006-01-02T15:04", req.LocalTime, loc)
		if err != nil || at.Format("2006-01-02T15:04") != req.LocalTime {
			response.BadRequest(c, "invalid local time or daylight-saving gap")
			return
		}
		req.NextAt = at.UTC()
	}
	if req.MissedPolicy == "" {
		req.MissedPolicy = "once"
	}
	if err := h.Schedules.Save(c.Request.Context(), owner, &req.AgentSchedule); err != nil {
		response.BadRequest(c, "valid owned bot, time, timezone and recurrence required")
		return
	}
	response.Success(c, req.AgentSchedule)
}
func (h *AgentMemoryScheduleHandler) ScheduleAction(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	if err := h.Schedules.Action(c.Request.Context(), owner, id, c.Param("action")); err != nil {
		response.BadRequest(c, "schedule action unavailable")
		return
	}
	response.Success(c, gin.H{"status": c.Param("action")})
}
func (h *AgentMemoryScheduleHandler) Start(ctx context.Context, onError func(error)) {
	go func() {
		timer := time.NewTicker(15 * time.Second)
		defer timer.Stop()
		for {
			if err := h.Schedules.Tick(ctx, time.Now().UTC()); err != nil {
				onError(err)
			}
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
			}
		}
	}()
}
