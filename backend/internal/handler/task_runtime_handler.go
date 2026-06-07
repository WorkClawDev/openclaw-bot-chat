package handler

import (
	"context"
	"errors"
	"io"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type TaskRuntimeHandler struct {
	taskService *service.TaskService
}

func NewTaskRuntimeHandler(taskService *service.TaskService) *TaskRuntimeHandler {
	return &TaskRuntimeHandler{taskService: taskService}
}

func (h *TaskRuntimeHandler) Create(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	var req service.CreateTaskRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.RuntimeCreate(c.Request.Context(), bot, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Created(c, responsedto.NewTaskResponse(task))
}

func (h *TaskRuntimeHandler) List(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	tasks, err := h.taskService.List(c.Request.Context(), bot.OwnerID)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponses(tasks))
}

func (h *TaskRuntimeHandler) Queue(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	tasks, err := h.taskService.RuntimeQueue(c.Request.Context(), bot)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponses(tasks))
}

func (h *TaskRuntimeHandler) Claim(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.RuntimeTaskNoteRequest
	if err := bindOptionalJSON(c, &req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.Claim(c.Request.Context(), bot, taskID, req.LatestStatusNote)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskRuntimeHandler) Progress(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.RuntimeTaskProgressRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.RuntimeProgress(c.Request.Context(), bot, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskRuntimeHandler) Complete(c *gin.Context) {
	h.result(c, h.taskService.RuntimeComplete)
}

func (h *TaskRuntimeHandler) Result(c *gin.Context) {
	h.result(c, h.taskService.RuntimeResult)
}

func (h *TaskRuntimeHandler) result(c *gin.Context, submit func(context.Context, *model.Bot, uuid.UUID, service.RuntimeTaskResultRequest) (*model.Task, error)) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.RuntimeTaskResultRequest
	if err := bindOptionalJSON(c, &req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := submit(c.Request.Context(), bot, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func (h *TaskRuntimeHandler) Fail(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	taskID, ok := parseTaskID(c)
	if !ok {
		return
	}
	var req service.RuntimeTaskFailRequest
	if err := bindOptionalJSON(c, &req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	task, err := h.taskService.RuntimeFail(c.Request.Context(), bot, taskID, req)
	if err != nil {
		writeTaskError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewTaskResponse(task))
}

func bindOptionalJSON(c *gin.Context, req interface{}) error {
	err := c.ShouldBindJSON(req)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}
