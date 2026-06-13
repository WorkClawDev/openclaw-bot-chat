package handler

import (
	"errors"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type DocumentHandler struct {
	docService *service.DocumentService
}

func NewDocumentHandler(docService *service.DocumentService) *DocumentHandler {
	return &DocumentHandler{docService: docService}
}

func (h *DocumentHandler) List(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	documents, err := h.docService.List(c.Request.Context(), ownerID, limit)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}
	apiresponse.Success(c, responsedto.NewDocumentResponses(documents))
}

func (h *DocumentHandler) Create(c *gin.Context) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	var req service.CreateDocumentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	document, err := h.docService.Create(c.Request.Context(), ownerID, req)
	if err != nil {
		writeDocumentError(c, err)
		return
	}
	apiresponse.Created(c, responsedto.NewDocumentResponse(document, true))
}

func (h *DocumentHandler) Get(c *gin.Context) {
	ownerID, documentID, ok := h.documentRouteContext(c)
	if !ok {
		return
	}
	document, err := h.docService.Get(c.Request.Context(), ownerID, documentID)
	if err != nil {
		writeDocumentError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewDocumentResponse(document, true))
}

func (h *DocumentHandler) Update(c *gin.Context) {
	ownerID, documentID, ok := h.documentRouteContext(c)
	if !ok {
		return
	}
	var req service.UpdateDocumentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	document, err := h.docService.Update(c.Request.Context(), ownerID, documentID, req)
	if err != nil {
		writeDocumentError(c, err)
		return
	}
	apiresponse.Success(c, responsedto.NewDocumentResponse(document, true))
}

func (h *DocumentHandler) Archive(c *gin.Context) {
	ownerID, documentID, ok := h.documentRouteContext(c)
	if !ok {
		return
	}
	if err := h.docService.Archive(c.Request.Context(), ownerID, documentID); err != nil {
		writeDocumentError(c, err)
		return
	}
	apiresponse.Success(c, gin.H{"message": "document archived"})
}

func (h *DocumentHandler) documentRouteContext(c *gin.Context) (uuid.UUID, uuid.UUID, bool) {
	ownerID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return uuid.Nil, uuid.Nil, false
	}
	documentID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		apiresponse.BadRequest(c, "invalid document id")
		return uuid.Nil, uuid.Nil, false
	}
	return ownerID, documentID, true
}

func writeDocumentError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, service.ErrDocumentNotFound):
		apiresponse.NotFound(c, err.Error())
	case errors.Is(err, service.ErrDocumentInvalidTitle),
		errors.Is(err, service.ErrDocumentInvalidBody):
		apiresponse.BadRequest(c, err.Error())
	default:
		apiresponse.InternalError(c, err.Error())
	}
}
