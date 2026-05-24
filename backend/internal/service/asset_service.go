package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/storage"
)

var (
	ErrAssetNotFound         = errors.New("asset not found")
	ErrAssetAccessDenied     = errors.New("you do not have access to this asset")
	ErrAssetNotReady         = errors.New("asset is not ready")
	ErrAssetInvalid          = errors.New("invalid asset payload")
	ErrAssetTooLarge         = errors.New("asset exceeds size limit")
	ErrAssetUnsupportedType  = errors.New("unsupported asset content type")
	ErrAssetProviderDisabled = errors.New("object storage is not configured")
)

type PrepareImageUploadRequest struct {
	FileName       string `json:"file_name"`
	ContentType    string `json:"content_type"`
	Size           int64  `json:"size"`
	ConversationID string `json:"conversation_id,omitempty"`
}

type CompleteImageUploadRequest struct {
	AssetID   string `json:"asset_id"`
	ObjectKey string `json:"object_key"`
}

type PreparedUpload struct {
	Asset  *model.AssetPayload      `json:"asset"`
	Upload *storage.PresignedUpload `json:"upload"`
}

type ImportBotImageRequest struct {
	SourceURL   string `json:"source_url,omitempty"`
	DataURL     string `json:"data_url,omitempty"`
	FileName    string `json:"file_name,omitempty"`
	ContentType string `json:"content_type,omitempty"`
}

type AssetService struct {
	repo       *repository.AssetRepository
	storage    storage.ObjectStorageProvider
	storageCfg config.StorageConfig
	assetCfg   config.AssetConfig
	httpClient *http.Client
}

func NewAssetService(repo *repository.AssetRepository, provider storage.ObjectStorageProvider, storageCfg config.StorageConfig, assetCfg config.AssetConfig) *AssetService {
	return &AssetService{
		repo:       repo,
		storage:    provider,
		storageCfg: storageCfg,
		assetCfg:   assetCfg,
		httpClient: &http.Client{Timeout: 30 * time.Second},
	}
}

func (s *AssetService) Enabled() bool {
	return s != nil && s.storage != nil
}

func (s *AssetService) PrepareImageUpload(ctx context.Context, ownerUserID uuid.UUID, req PrepareImageUploadRequest) (*PreparedUpload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}

	contentType := strings.ToLower(strings.TrimSpace(req.ContentType))
	if !isAllowedImageContentType(contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if req.Size <= 0 {
		return nil, ErrAssetInvalid
	}
	if s.assetCfg.MaxImageSizeMB > 0 && req.Size > int64(s.assetCfg.MaxImageSizeMB)*1024*1024 {
		return nil, ErrAssetTooLarge
	}

	assetID := uuid.New()
	objectKey := s.buildObjectKey(ownerUserID.String(), req.FileName, contentType)
	asset := &model.Asset{
		ID:              assetID,
		Kind:            model.AssetKindImage,
		StorageProvider: s.storage.Provider(),
		Bucket:          s.storage.Bucket(),
		ObjectKey:       objectKey,
		MIMEType:        contentType,
		Size:            req.Size,
		FileName:        sanitizeFileName(req.FileName),
		Status:          model.AssetStatusPending,
		OwnerUserID:     &ownerUserID,
	}
	if err := s.repo.Create(ctx, asset); err != nil {
		return nil, err
	}

	upload, err := s.storage.CreatePresignedUpload(ctx, objectKey, contentType, time.Duration(s.storageCfg.UploadURLTTL)*time.Second)
	if err != nil {
		return nil, err
	}

	payload, err := s.buildAssetPayload(ctx, asset)
	if err != nil {
		return nil, err
	}

	return &PreparedUpload{
		Asset:  payload,
		Upload: upload,
	}, nil
}

func (s *AssetService) CompleteImageUpload(ctx context.Context, ownerUserID uuid.UUID, req CompleteImageUploadRequest) (*model.AssetPayload, error) {
	assetID, err := uuid.Parse(strings.TrimSpace(req.AssetID))
	if err != nil {
		return nil, ErrAssetInvalid
	}

	asset, err := s.repo.GetByID(ctx, assetID)
	if err != nil {
		return nil, ErrAssetNotFound
	}
	if asset.OwnerUserID == nil || *asset.OwnerUserID != ownerUserID {
		return nil, ErrAssetAccessDenied
	}
	if req.ObjectKey != "" && req.ObjectKey != asset.ObjectKey {
		return nil, ErrAssetInvalid
	}

	info, err := s.storage.StatObject(ctx, asset.ObjectKey)
	if err != nil {
		return nil, err
	}
	if asset.Size > 0 && info.ContentLength > 0 && asset.Size != info.ContentLength {
		return nil, ErrAssetInvalid
	}
	if asset.MIMEType != "" && info.ContentType != "" && !strings.EqualFold(asset.MIMEType, info.ContentType) {
		return nil, ErrAssetInvalid
	}

	asset.Size = firstPositiveInt64(info.ContentLength, asset.Size)
	if info.ContentType != "" {
		asset.MIMEType = info.ContentType
	}
	asset.Status = model.AssetStatusReady
	if err := s.repo.Update(ctx, asset); err != nil {
		return nil, err
	}

	return s.buildAssetPayload(ctx, asset)
}

func (s *AssetService) GetPublicImageURL(ctx context.Context, assetID string) (string, error) {
	if !s.Enabled() {
		return "", ErrAssetProviderDisabled
	}

	parsedID, err := uuid.Parse(strings.TrimSpace(assetID))
	if err != nil {
		return "", ErrAssetInvalid
	}

	asset, err := s.repo.GetByID(ctx, parsedID)
	if err != nil {
		return "", ErrAssetNotFound
	}
	if asset.Kind != model.AssetKindImage {
		return "", ErrAssetUnsupportedType
	}
	if asset.Status != model.AssetStatusReady {
		return "", ErrAssetNotReady
	}

	payload, err := s.buildAssetPayload(ctx, asset)
	if err != nil {
		return "", err
	}
	switch {
	case payload.DownloadURL != "":
		return payload.DownloadURL, nil
	case payload.ExternalURL != "":
		return payload.ExternalURL, nil
	case payload.SourceURL != "":
		return payload.SourceURL, nil
	default:
		return "", ErrAssetNotReady
	}
}

func (s *AssetService) ResolveMessageAsset(ctx context.Context, senderType string, senderID string, contentType string, meta map[string]interface{}) (map[string]interface{}, error) {
	if contentType != string(model.MsgTypeImage) || len(meta) == 0 {
		return model.RemoveEphemeralAssetFields(meta), nil
	}

	payload := model.AssetPayloadFromMap(meta)
	if payload == nil {
		return nil, ErrAssetInvalid
	}

	if payload.ID != "" {
		resolved, err := s.resolveStoredAsset(ctx, senderType, senderID, payload.ID)
		if err != nil {
			return nil, err
		}
		return model.UpsertAssetPayload(meta, resolved), nil
	}

	if payload.SourceURL != "" && senderType == "bot" {
		botID, err := uuid.Parse(senderID)
		if err != nil {
			return nil, ErrAssetInvalid
		}
		imported, err := s.ImportRemoteImageForBot(ctx, botID, payload.SourceURL)
		if err != nil {
			return nil, err
		}
		return model.UpsertAssetPayload(meta, imported), nil
	}

	if payload.ExternalURL != "" || payload.SourceURL != "" {
		return model.UpsertAssetPayload(meta, sanitizeExternalAssetPayload(payload)), nil
	}

	return nil, ErrAssetInvalid
}

func (s *AssetService) HydrateMessageAsset(ctx context.Context, meta map[string]interface{}) map[string]interface{} {
	if !s.Enabled() || len(meta) == 0 {
		return meta
	}

	payload := model.AssetPayloadFromMap(meta)
	if payload == nil || payload.ID == "" {
		return meta
	}

	assetID, err := uuid.Parse(payload.ID)
	if err != nil {
		return meta
	}
	asset, err := s.repo.GetByID(ctx, assetID)
	if err != nil {
		return meta
	}

	enriched, err := s.buildAssetPayload(ctx, asset)
	if err != nil {
		return meta
	}
	return model.UpsertAssetPayload(meta, enriched)
}

func (s *AssetService) ImportImageForBot(ctx context.Context, botID uuid.UUID, req ImportBotImageRequest) (*model.AssetPayload, error) {
	if req.SourceURL != "" {
		return s.ImportRemoteImageForBot(ctx, botID, req.SourceURL)
	}
	if req.DataURL == "" {
		return nil, ErrAssetInvalid
	}

	contentType, payload, err := decodeImageDataURL(req.DataURL)
	if err != nil {
		return nil, err
	}
	if req.ContentType != "" {
		contentType = strings.ToLower(strings.TrimSpace(req.ContentType))
	}
	if !isAllowedImageContentType(contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if s.assetCfg.MaxImageSizeMB > 0 && int64(len(payload)) > int64(s.assetCfg.MaxImageSizeMB)*1024*1024 {
		return nil, ErrAssetTooLarge
	}

	return s.importImageBytesForBot(ctx, botID, payload, req.FileName, contentType, "")
}

func (s *AssetService) buildAssetPayload(ctx context.Context, asset *model.Asset) (*model.AssetPayload, error) {
	if asset == nil {
		return nil, ErrAssetNotFound
	}

	payload := &model.AssetPayload{
		ID:              asset.ID.String(),
		Kind:            string(asset.Kind),
		Status:          string(asset.Status),
		StorageProvider: asset.StorageProvider,
		Bucket:          asset.Bucket,
		ObjectKey:       asset.ObjectKey,
		MIMEType:        asset.MIMEType,
		Size:            asset.Size,
		FileName:        asset.FileName,
		Width:           asset.Width,
		Height:          asset.Height,
	}
	if asset.SHA256 != nil {
		payload.SHA256 = *asset.SHA256
	}
	if asset.SourceURL != nil {
		payload.SourceURL = *asset.SourceURL
	}

	if asset.Status == model.AssetStatusReady && asset.ObjectKey != "" && s.storageCfg.PrivateRead {
		downloadURL, expiresAt, err := s.storage.CreatePresignedDownload(ctx, asset.ObjectKey, time.Duration(s.storageCfg.DownloadURLTTL)*time.Second)
		if err == nil {
			payload.DownloadURL = downloadURL
			payload.DownloadURLExpiresAt = &expiresAt
		}
	}

	if payload.DownloadURL == "" && !s.storageCfg.PrivateRead && s.storageCfg.PublicBaseURL != "" {
		payload.DownloadURL = strings.TrimRight(s.storageCfg.PublicBaseURL, "/") + "/" + strings.TrimLeft(asset.ObjectKey, "/")
	}

	return payload, nil
}

func (s *AssetService) resolveStoredAsset(ctx context.Context, senderType string, senderID string, assetID string) (*model.AssetPayload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}

	parsedID, err := uuid.Parse(assetID)
	if err != nil {
		return nil, ErrAssetInvalid
	}
	asset, err := s.repo.GetByID(ctx, parsedID)
	if err != nil {
		return nil, ErrAssetNotFound
	}
	if asset.Status != model.AssetStatusReady {
		return nil, ErrAssetNotReady
	}
	if !assetOwnedBySender(asset, senderType, senderID) {
		return nil, ErrAssetAccessDenied
	}
	return s.buildAssetPayload(ctx, asset)
}

func (s *AssetService) buildObjectKey(ownerKey string, fileName string, contentType string) string {
	ext := strings.ToLower(path.Ext(fileName))
	if ext == "" {
		if guessed := mimeExtensionFromType(contentType); guessed != "" {
			ext = guessed
		}
	}

	now := time.Now().UTC()
	return fmt.Sprintf("%s/%04d/%02d/%s/%s%s",
		strings.Trim(s.storageCfg.KeyPrefix, "/"),
		now.Year(),
		now.Month(),
		ownerKey,
		uuid.NewString(),
		ext,
	)
}

func (s *AssetService) ImportRemoteImageForBot(ctx context.Context, botID uuid.UUID, sourceURL string) (*model.AssetPayload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("download remote asset failed with status %d", resp.StatusCode)
	}

	contentType := strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Type")))
	if !isAllowedImageContentType(contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if s.assetCfg.MaxImageSizeMB > 0 && resp.ContentLength > int64(s.assetCfg.MaxImageSizeMB)*1024*1024 {
		return nil, ErrAssetTooLarge
	}

	var buffer bytes.Buffer
	hasher := sha256.New()
	reader := io.TeeReader(resp.Body, hasher)
	limited := io.LimitReader(reader, int64(s.assetCfg.MaxImageSizeMB+1)*1024*1024)
	size, err := io.Copy(&buffer, limited)
	if err != nil {
		return nil, err
	}
	if s.assetCfg.MaxImageSizeMB > 0 && size > int64(s.assetCfg.MaxImageSizeMB)*1024*1024 {
		return nil, ErrAssetTooLarge
	}

	return s.importImageBytesForBot(ctx, botID, buffer.Bytes(), path.Base(req.URL.Path), contentType, sourceURL)
}

func assetOwnedBySender(asset *model.Asset, senderType string, senderID string) bool {
	switch senderType {
	case "user":
		return asset.OwnerUserID != nil && asset.OwnerUserID.String() == senderID
	case "bot":
		return asset.OwnerBotID != nil && asset.OwnerBotID.String() == senderID
	default:
		return false
	}
}

func isAllowedImageContentType(contentType string) bool {
	switch contentType {
	case "image/jpeg", "image/png", "image/webp", "image/gif":
		return true
	default:
		return false
	}
}

func (s *AssetService) importImageBytesForBot(
	ctx context.Context,
	botID uuid.UUID,
	payload []byte,
	fileName string,
	contentType string,
	sourceURL string,
) (*model.AssetPayload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}
	if !isAllowedImageContentType(contentType) {
		return nil, ErrAssetUnsupportedType
	}

	size := int64(len(payload))
	if size <= 0 {
		return nil, ErrAssetInvalid
	}
	if s.assetCfg.MaxImageSizeMB > 0 && size > int64(s.assetCfg.MaxImageSizeMB)*1024*1024 {
		return nil, ErrAssetTooLarge
	}

	normalizedFileName := sanitizeFileName(fileName)
	if normalizedFileName == "" {
		normalizedFileName = fmt.Sprintf("%s%s", botID.String(), fileExtensionForContentType(contentType))
	}

	width, height := decodeImageDimensions(payload)
	sumBytes := sha256.Sum256(payload)
	sum := hex.EncodeToString(sumBytes[:])
	objectKey := s.buildObjectKey(botID.String(), normalizedFileName, contentType)

	if _, err := s.storage.PutObject(ctx, storage.PutObjectInput{
		ObjectKey:     objectKey,
		Reader:        bytes.NewReader(payload),
		ContentType:   contentType,
		ContentLength: size,
	}); err != nil {
		return nil, err
	}

	asset := &model.Asset{
		ID:              uuid.New(),
		Kind:            model.AssetKindImage,
		StorageProvider: s.storage.Provider(),
		Bucket:          s.storage.Bucket(),
		ObjectKey:       objectKey,
		MIMEType:        contentType,
		Size:            size,
		FileName:        normalizedFileName,
		Status:          model.AssetStatusReady,
		OwnerBotID:      &botID,
	}
	if sourceURL != "" {
		asset.SourceURL = &sourceURL
	}
	if width > 0 {
		asset.Width = &width
	}
	if height > 0 {
		asset.Height = &height
	}
	if sum != "" {
		asset.SHA256 = &sum
	}
	if err := s.repo.Create(ctx, asset); err != nil {
		return nil, err
	}

	return s.buildAssetPayload(ctx, asset)
}

func decodeImageDataURL(value string) (string, []byte, error) {
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(value)), "data:") {
		return "", nil, ErrAssetInvalid
	}

	header, encoded, ok := strings.Cut(value, ",")
	if !ok {
		return "", nil, ErrAssetInvalid
	}

	mediaType := strings.TrimPrefix(header, "data:")
	parts := strings.Split(mediaType, ";")
	contentType := strings.ToLower(strings.TrimSpace(parts[0]))
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	isBase64 := false
	for _, part := range parts[1:] {
		if strings.EqualFold(strings.TrimSpace(part), "base64") {
			isBase64 = true
			break
		}
	}
	if !isBase64 {
		return "", nil, ErrAssetInvalid
	}

	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", nil, ErrAssetInvalid
	}
	return contentType, decoded, nil
}

func fileExtensionForContentType(contentType string) string {
	switch contentType {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	default:
		return ""
	}
}

func sanitizeFileName(fileName string) string {
	name := strings.TrimSpace(path.Base(fileName))
	if name == "" || name == "." || name == "/" {
		return "image"
	}
	return name
}

func mimeExtensionFromType(contentType string) string {
	switch contentType {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	default:
		return ""
	}
}

func sanitizeExternalAssetPayload(payload *model.AssetPayload) *model.AssetPayload {
	if payload == nil {
		return nil
	}
	copy := *payload
	copy.DownloadURL = ""
	copy.DownloadURLExpiresAt = nil
	copy.StorageProvider = ""
	copy.Bucket = ""
	copy.ObjectKey = ""
	copy.Status = ""
	return &copy
}

func firstPositiveInt64(values ...int64) int64 {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

func decodeImageDimensions(content []byte) (int, int) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(content))
	if err != nil {
		return 0, 0
	}
	return cfg.Width, cfg.Height
}
