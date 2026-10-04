package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"io"
	"net/http"
	"time"
	"unicode/utf8"
)

const MaxFileSizeBytes = 8 * 1024 * 1024

func (s *AssetService) PrepareFileUpload(ctx context.Context, owner uuid.UUID, req PrepareImageUploadRequest) (*PreparedUpload, error) {
	if !s.storageCfg.PrivateRead {
		return nil, ErrAssetProviderDisabled
	}
	return s.prepareAssetUpload(ctx, owner, req, model.AssetKindFile)
}
func (s *AssetService) CompleteFileUpload(ctx context.Context, owner uuid.UUID, req CompleteImageUploadRequest) (*model.AssetPayload, error) {
	return s.completeAssetUpload(ctx, owner, req, model.AssetKindFile)
}
func (s *AssetService) ImportFileBytesForBot(ctx context.Context, bot *model.Bot, payload []byte, fileName, contentType string, metadata model.JSONMap) (*model.AssetPayload, error) {
	if !s.storageCfg.PrivateRead {
		return nil, ErrAssetProviderDisabled
	}
	if err := validateFileBytes(payload, contentType); err != nil {
		return nil, err
	}
	result, err := s.importAssetBytesForBot(ctx, bot.ID, model.AssetKindFile, payload, fileName, contentType, "")
	if err != nil {
		return nil, err
	}
	id, _ := uuid.Parse(result.ID)
	asset, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	asset.OwnerUserID = &bot.OwnerID
	asset.Metadata = metadata
	if err = s.repo.Update(ctx, asset); err != nil {
		return nil, err
	}
	return s.buildAssetPayload(ctx, asset)
}
func (s *AssetService) FileForOwner(ctx context.Context, owner uuid.UUID, bot *uuid.UUID, assetID string) (*model.AssetPayload, error) {
	id, err := uuid.Parse(assetID)
	if err != nil {
		return nil, ErrAssetInvalid
	}
	asset, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, ErrAssetNotFound
	}
	if asset.Kind != model.AssetKindFile || asset.Status != model.AssetStatusReady {
		return nil, ErrAssetNotReady
	}
	if (asset.OwnerUserID == nil || *asset.OwnerUserID != owner) && (bot == nil || asset.OwnerBotID == nil || *asset.OwnerBotID != *bot) {
		return nil, ErrAssetAccessDenied
	}
	return s.buildAssetPayload(ctx, asset)
}
func isAllowedFileContentType(mime string) bool {
	switch normalizeAssetContentType(mime) {
	case "text/plain", "text/markdown", "text/csv", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
		return true
	}
	return false
}

func (s *AssetService) verifyStoredFile(ctx context.Context, asset *model.Asset) error {
	if asset.Size <= 0 || asset.Size > MaxFileSizeBytes {
		return ErrAssetTooLarge
	}
	download, err := s.fileDownloadURL(ctx, asset.ObjectKey)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, download, nil)
	if err != nil {
		return err
	}
	client := *s.httpClient
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	reply, err := client.Do(request)
	if err != nil {
		return err
	}
	defer reply.Body.Close()
	if reply.StatusCode != http.StatusOK {
		return ErrAssetInvalid
	}
	payload, err := io.ReadAll(io.LimitReader(reply.Body, MaxFileSizeBytes+1))
	if err != nil {
		return err
	}
	if len(payload) > MaxFileSizeBytes || int64(len(payload)) != asset.Size {
		return ErrAssetInvalid
	}
	if err = validateFileBytes(payload, asset.MIMEType); err != nil {
		return err
	}
	hash := sha256.Sum256(payload)
	sum := hex.EncodeToString(hash[:])
	asset.SHA256 = &sum
	return nil
}
func validateFileBytes(payload []byte, mime string) error {
	if len(payload) == 0 || len(payload) > MaxFileSizeBytes {
		return ErrAssetInvalid
	}
	switch normalizeAssetContentType(mime) {
	case "application/pdf":
		if !bytes.HasPrefix(payload, []byte("%PDF-")) {
			return ErrAssetInvalid
		}
	case "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
		if !bytes.HasPrefix(payload, []byte{'P', 'K', 3, 4}) {
			return ErrAssetInvalid
		}
	case "text/plain", "text/markdown", "text/csv":
		if !utf8.Valid(payload) {
			return ErrAssetInvalid
		}
	default:
		return ErrAssetUnsupportedType
	}
	return nil
}

func (s *AssetService) fileDownloadURL(ctx context.Context, key string) (string, error) {
	if p, ok := s.storage.(interface {
		CreateInternalDownload(context.Context, string, time.Duration) (string, error)
	}); ok {
		return p.CreateInternalDownload(ctx, key, time.Minute)
	}
	url, _, err := s.storage.CreatePresignedDownload(ctx, key, time.Minute)
	return url, err
}
func (s *AssetService) FileBytesForOwner(ctx context.Context, owner uuid.UUID, bot *uuid.UUID, id string) ([]byte, error) {
	if _, err := s.FileForOwner(ctx, owner, bot, id); err != nil {
		return nil, err
	}
	assetID, _ := uuid.Parse(id)
	asset, err := s.repo.GetByID(ctx, assetID)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	url, err := s.fileDownloadURL(ctx, asset.ObjectKey)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	client := *s.httpClient
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	reply, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer reply.Body.Close()
	if reply.StatusCode != http.StatusOK {
		return nil, ErrAssetInvalid
	}
	data, err := io.ReadAll(io.LimitReader(reply.Body, MaxFileSizeBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != asset.Size || len(data) > MaxFileSizeBytes {
		return nil, ErrAssetInvalid
	}
	sum := sha256.Sum256(data)
	if asset.SHA256 == nil || hex.EncodeToString(sum[:]) != *asset.SHA256 {
		return nil, ErrAssetInvalid
	}
	return data, nil
}
