package handler

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	response "github.com/openclaw-bot-chat/backend/pkg/response"
	"gorm.io/gorm"
	"net/http"
	"path"
	"strings"
)

type AgentFileHandler struct {
	assets    *service.AssetService
	documents *service.DocumentService
	repo      *repository.AgentArtifactRepository
	runs      *AgentRunHandler
}

func NewAgentFileHandler(assets *service.AssetService, docs *service.DocumentService, repo *repository.AgentArtifactRepository, runs *AgentRunHandler) *AgentFileHandler {
	return &AgentFileHandler{assets: assets, documents: docs, repo: repo, runs: runs}
}
func (h *AgentFileHandler) RegisterRuntime(r *gin.RouterGroup) {
	r.GET("/files/:id", h.RuntimeFile)
	r.POST("/artifacts", h.runs.Fence(h.Import))
}
func (h *AgentFileHandler) RegisterUser(r *gin.RouterGroup) {
	r.GET("/runs/:id/artifacts", h.List)
	r.GET("/artifacts/:id/download", h.Download)
}
func (h *AgentFileHandler) RuntimeFile(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	asset, err := h.assets.FileForOwner(c.Request.Context(), bot.OwnerID, &bot.ID, c.Param("id"))
	if err != nil {
		response.NotFound(c, "file unavailable or not owned")
		return
	}
	response.Success(c, asset)
}
func (h *AgentFileHandler) List(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	if _, err := h.runs.Repo.Get(c.Request.Context(), owner, nil, id); err != nil {
		response.NotFound(c, "run not found")
		return
	}
	rows, err := h.repo.List(c.Request.Context(), owner, id)
	if err != nil {
		response.InternalError(c, "artifact lookup failed")
		return
	}
	response.Success(c, rows)
}
func (h *AgentFileHandler) Download(c *gin.Context) {
	owner, _ := middleware.GetUserID(c)
	id, ok := runID(c)
	if !ok {
		return
	}
	row, err := h.repo.Get(c.Request.Context(), owner, id)
	if err != nil {
		response.NotFound(c, "artifact not found")
		return
	}
	asset, err := h.assets.FileForOwner(c.Request.Context(), owner, nil, row.AssetID.String())
	if err != nil {
		response.NotFound(c, "file unavailable")
		return
	}
	response.Success(c, asset)
}
func (h *AgentFileHandler) Import(c *gin.Context) {
	bot, _ := middleware.GetBot(c)
	runID, err := uuid.Parse(c.GetHeader("X-Agent-Run"))
	if err != nil {
		response.BadRequest(c, "run required")
		return
	}
	run, err := h.runs.Repo.Get(c.Request.Context(), bot.OwnerID, &bot.ID, runID)
	if err != nil {
		response.NotFound(c, "run not found")
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 12*1024*1024)
	var req struct {
		FileName string `json:"file_name"`
		MIMEType string `json:"mime_type"`
		Base64   string `json:"content_base64"`
	}
	if c.ShouldBindJSON(&req) != nil || req.FileName == "" || len(req.FileName) > 256 {
		response.BadRequest(c, "invalid artifact")
		return
	}
	payload, err := base64.StdEncoding.DecodeString(req.Base64)
	if err != nil || len(payload) > service.MaxFileSizeBytes {
		response.BadRequest(c, "invalid or oversized artifact")
		return
	}
	name := path.Base(strings.ReplaceAll(req.FileName, "\\", "/"))
	sum := sha256.Sum256(payload)
	hash := hex.EncodeToString(sum[:])
	prior, err := h.repo.Find(c.Request.Context(), bot.OwnerID, runID, name, hash)
	if err == nil {
		response.Success(c, prior)
		return
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		response.InternalError(c, "artifact lookup failed")
		return
	}
	asset, err := h.assets.ImportFileBytesForBot(c.Request.Context(), bot, payload, name, req.MIMEType, model.JSONMap{"run_id": runID, "task_id": run.TaskID})
	if err != nil {
		response.BadRequest(c, err.Error())
		return
	}
	assetID, _ := uuid.Parse(asset.ID)
	row := &model.AgentArtifact{OwnerID: bot.OwnerID, BotID: bot.ID, RunID: runID, TaskID: run.TaskID, AssetID: assetID, FileName: name, MIMEType: asset.MIMEType, SHA256: hash, Size: asset.Size}
	if req.MIMEType == "text/markdown" || req.MIMEType == "text/plain" {
		doc, err := h.documents.CreateFromBot(c.Request.Context(), bot.OwnerID, bot.ID, service.CreateDocumentRequest{Title: name, Body: string(payload), ConversationID: run.Conversation, Metadata: map[string]interface{}{"run_id": runID, "asset_id": asset.ID}})
		if err != nil {
			response.BadRequest(c, "document persistence failed")
			return
		}
		row.DocumentID = &doc.ID
	}
	if err = h.repo.Create(c.Request.Context(), row); err != nil {
		response.InternalError(c, "artifact persistence failed")
		return
	}
	response.Success(c, row)
}
