package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type AssetHandler struct {
	assetService *service.AssetService
}

func NewAssetHandler(assetService *service.AssetService) *AssetHandler {
	return &AssetHandler{assetService: assetService}
}

func (h *AssetHandler) PrepareImageUpload(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	var req service.PrepareImageUploadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	prepared, err := h.assetService.PrepareImageUpload(c.Request.Context(), userID, req)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrAssetProviderDisabled),
			errors.Is(err, service.ErrAssetTooLarge),
			errors.Is(err, service.ErrAssetUnsupportedType),
			errors.Is(err, service.ErrAssetInvalid):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	apiresponse.Success(c, responsedto.NewPreparedUploadResponse(prepared))
}

func (h *AssetHandler) CompleteImageUpload(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	var req service.CompleteImageUploadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	asset, err := h.assetService.CompleteImageUpload(c.Request.Context(), userID, req)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrAssetNotFound):
			apiresponse.NotFound(c, err.Error())
		case errors.Is(err, service.ErrAssetAccessDenied):
			apiresponse.Forbidden(c, err.Error())
		case errors.Is(err, service.ErrAssetInvalid),
			errors.Is(err, service.ErrAssetNotReady):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	apiresponse.Success(c, responsedto.NewAssetResponse(asset))
}

func (h *AssetHandler) RedirectPublicImage(c *gin.Context) {
	assetID := c.Param("id")
	url, err := h.assetService.GetPublicImageURL(c.Request.Context(), assetID)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrAssetNotFound):
			apiresponse.NotFound(c, err.Error())
		case errors.Is(err, service.ErrAssetInvalid),
			errors.Is(err, service.ErrAssetUnsupportedType),
			errors.Is(err, service.ErrAssetNotReady),
			errors.Is(err, service.ErrAssetProviderDisabled):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	c.Header("Cache-Control", "private, max-age=300")
	c.Redirect(http.StatusTemporaryRedirect, url)
}
