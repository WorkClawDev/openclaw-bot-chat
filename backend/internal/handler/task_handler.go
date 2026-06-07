package handler

import (
	"context"
	"errors"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type TaskHandler struct {
	taskService *service.TaskService
}

func NewTaskHandler(taskService *service.TaskService) *TaskHandler {
	return &TaskHandler{taskService: taskService}
}

func (h *TaskHandler) List(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	tasks, err := h.taskService.List(c.Request.Context(), ownerID)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponses(tasks))
}

func (h *TaskHandler) Create(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	var req service.CreateTaskRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.Create(c.Request.Context(), ownerID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Created(c, responsedto.NewTaskResponse(task))
}

func (h *TaskHandler) Get(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	task, err := h.taskService.Get(c.Request.Context(), ownerID, taskID)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskHandler) Update(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.UpdateTaskRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.Update(c.Request.Context(), ownerID, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskHandler) Reassign(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.ReassignTaskRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.Reassign(c.Request.Context(), ownerID, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskHandler) Dispatch(c *gin.Context) {
	h.userAction(c, h.taskService.Dispatch)
}

func (h *TaskHandler) Accept(c *gin.Context) {
	h.userAction(c, h.taskService.Accept)
}

func (h *TaskHandler) Reject(c *gin.Context) {
	h.userAction(c, h.taskService.Reject)
}

func (h *TaskHandler) Retry(c *gin.Context) {
	h.userAction(c, h.taskService.Retry)
}

func (h *TaskHandler) Cancel(c *gin.Context) {
	h.userAction(c, h.taskService.Cancel)
}

func (h *TaskHandler) Delete(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	if err := h.taskService.Delete(c.Request.Context(), ownerID, taskID); err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, gin.H{"message": "task deleted"})
}

func (h *TaskHandler) userAction(
	c *gin.Context,
	action func(context.Context, uuid.UUID, uuid.UUID, service.UserTaskActionRequest) (*model.Task, error),
) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.UserTaskActionRequest
	if err := bindOptionalJSON(c, &req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := action(c.Request.Context(), ownerID, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func parseTaskID(c *gin.Context) (uuid.UUID, bool) {
	taskID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		apiresponse.BadRequest(c, "invalid task id")
		return uuid.Nil, false
	}
	return taskID, true
}

func writeTaskError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, service.ErrTaskNotFound):
		apiresponse.NotFound(c, err.Error())
	case errors.Is(err, service.ErrTaskUnavailable):
		apiresponse.Conflict(c, err.Error())
	case errors.Is(err, service.ErrTaskHasDependents):
		apiresponse.Conflict(c, err.Error())
	case errors.Is(err, service.ErrTaskNotAssigned):
		apiresponse.Forbidden(c, err.Error())
	case errors.Is(err, service.ErrTaskInvalidStatus),
		errors.Is(err, service.ErrTaskInvalidPriority),
		errors.Is(err, service.ErrTaskInvalidProgress),
		errors.Is(err, service.ErrTaskInvalidDates),
		errors.Is(err, service.ErrTaskInvalidDependency),
		errors.Is(err, service.ErrTaskInvalidTitle),
		errors.Is(err, service.ErrBotNotFound):
		apiresponse.BadRequest(c, err.Error())
	default:
		apiresponse.InternalError(c, err.Error())
	}
}
