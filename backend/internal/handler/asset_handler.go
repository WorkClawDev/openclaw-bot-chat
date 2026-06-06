package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
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
	h.prepareUpload(c, "image")
}

func (h *AssetHandler) PrepareAudioUpload(c *gin.Context) {
	h.prepareUpload(c, "audio")
}

func (h *AssetHandler) prepareUpload(c *gin.Context, kind string) {
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

	var prepared *service.PreparedUpload
	var err error
	switch kind {
	case "audio":
		prepared, err = h.assetService.PrepareAudioUpload(c.Request.Context(), userID, req)
	default:
		prepared, err = h.assetService.PrepareImageUpload(c.Request.Context(), userID, req)
	}
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
	h.completeUpload(c, "image")
}

func (h *AssetHandler) CompleteAudioUpload(c *gin.Context) {
	h.completeUpload(c, "audio")
}

func (h *AssetHandler) completeUpload(c *gin.Context, kind string) {
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

	var asset *model.AssetPayload
	var err error
	switch kind {
	case "audio":
		asset, err = h.assetService.CompleteAudioUpload(c.Request.Context(), userID, req)
	default:
		asset, err = h.assetService.CompleteImageUpload(c.Request.Context(), userID, req)
	}
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
	h.redirectPublicAsset(c, "image")
}

func (h *AssetHandler) RedirectPublicAudio(c *gin.Context) {
	h.redirectPublicAsset(c, "audio")
}

func (h *AssetHandler) redirectPublicAsset(c *gin.Context, kind string) {
	assetID := c.Param("id")
	var url string
	var err error
	switch kind {
	case "audio":
		url, err = h.assetService.GetPublicAudioURL(c.Request.Context(), assetID)
	default:
		url, err = h.assetService.GetPublicImageURL(c.Request.Context(), assetID)
	}
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
