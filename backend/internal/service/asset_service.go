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

type PrepareAudioUploadRequest = PrepareImageUploadRequest
type CompleteAudioUploadRequest = CompleteImageUploadRequest

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

type ImportBotAudioRequest = ImportBotImageRequest

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
	return s.prepareAssetUpload(ctx, ownerUserID, req, model.AssetKindImage)
}

func (s *AssetService) PrepareAudioUpload(ctx context.Context, ownerUserID uuid.UUID, req PrepareAudioUploadRequest) (*PreparedUpload, error) {
	return s.prepareAssetUpload(ctx, ownerUserID, req, model.AssetKindAudio)
}

func (s *AssetService) prepareAssetUpload(ctx context.Context, ownerUserID uuid.UUID, req PrepareImageUploadRequest, kind model.AssetKind) (*PreparedUpload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}

	contentType := normalizeAssetContentType(req.ContentType)
	if !isAllowedAssetContentType(kind, contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if req.Size <= 0 {
		return nil, ErrAssetInvalid
	}
	if maxSize := s.maxAssetSizeBytes(kind); maxSize > 0 && req.Size > maxSize {
		return nil, ErrAssetTooLarge
	}

	assetID := uuid.New()
	objectKey := s.buildObjectKey(ownerUserID.String(), req.FileName, contentType)
	asset := &model.Asset{
		ID:              assetID,
		Kind:            kind,
		StorageProvider: s.storage.Provider(),
		Bucket:          s.storage.Bucket(),
		ObjectKey:       objectKey,
		MIMEType:        contentType,
		Size:            req.Size,
		FileName:        sanitizeAssetFileName(req.FileName, kind),
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
	return s.completeAssetUpload(ctx, ownerUserID, req, model.AssetKindImage)
}

func (s *AssetService) CompleteAudioUpload(ctx context.Context, ownerUserID uuid.UUID, req CompleteAudioUploadRequest) (*model.AssetPayload, error) {
	return s.completeAssetUpload(ctx, ownerUserID, req, model.AssetKindAudio)
}

func (s *AssetService) completeAssetUpload(ctx context.Context, ownerUserID uuid.UUID, req CompleteImageUploadRequest, kind model.AssetKind) (*model.AssetPayload, error) {
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
	if asset.Kind != kind {
		return nil, ErrAssetUnsupportedType
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
	return s.getPublicAssetURL(ctx, assetID, model.AssetKindImage)
}

func (s *AssetService) GetPublicAudioURL(ctx context.Context, assetID string) (string, error) {
	return s.getPublicAssetURL(ctx, assetID, model.AssetKindAudio)
}

func (s *AssetService) getPublicAssetURL(ctx context.Context, assetID string, kind model.AssetKind) (string, error) {
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
	if asset.Kind != kind {
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
	kind, ok := assetKindForMessageType(contentType)
	if !ok || len(meta) == 0 {
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
		if resolved.Kind != string(kind) {
			return nil, ErrAssetUnsupportedType
		}
		return model.UpsertAssetPayload(meta, resolved), nil
	}

	if payload.SourceURL != "" && senderType == "bot" {
		botID, err := uuid.Parse(senderID)
		if err != nil {
			return nil, ErrAssetInvalid
		}
		imported, err := s.ImportRemoteAssetForBot(ctx, botID, kind, payload.SourceURL)
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
	return s.importAssetForBot(ctx, botID, model.AssetKindImage, req)
}

func (s *AssetService) ImportAudioForBot(ctx context.Context, botID uuid.UUID, req ImportBotAudioRequest) (*model.AssetPayload, error) {
	return s.importAssetForBot(ctx, botID, model.AssetKindAudio, req)
}

func (s *AssetService) ImportImageBytesForBot(ctx context.Context, botID uuid.UUID, payload []byte, fileName string, contentType string) (*model.AssetPayload, error) {
	return s.importAssetBytesForBot(ctx, botID, model.AssetKindImage, payload, fileName, contentType, "")
}

func (s *AssetService) ImportAudioBytesForBot(ctx context.Context, botID uuid.UUID, payload []byte, fileName string, contentType string) (*model.AssetPayload, error) {
	return s.importAssetBytesForBot(ctx, botID, model.AssetKindAudio, payload, fileName, contentType, "")
}

func (s *AssetService) importAssetForBot(ctx context.Context, botID uuid.UUID, kind model.AssetKind, req ImportBotImageRequest) (*model.AssetPayload, error) {
	if req.SourceURL != "" {
		return s.ImportRemoteAssetForBot(ctx, botID, kind, req.SourceURL)
	}
	if req.DataURL == "" {
		return nil, ErrAssetInvalid
	}

	contentType, payload, err := decodeAssetDataURL(req.DataURL)
	if err != nil {
		return nil, err
	}
	if req.ContentType != "" {
		contentType = normalizeAssetContentType(req.ContentType)
	}
	if !isAllowedAssetContentType(kind, contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if maxSize := s.maxAssetSizeBytes(kind); maxSize > 0 && int64(len(payload)) > maxSize {
		return nil, ErrAssetTooLarge
	}

	return s.importAssetBytesForBot(ctx, botID, kind, payload, req.FileName, contentType, "")
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
	return s.ImportRemoteAssetForBot(ctx, botID, model.AssetKindImage, sourceURL)
}

func (s *AssetService) ImportRemoteAssetForBot(ctx context.Context, botID uuid.UUID, kind model.AssetKind, sourceURL string) (*model.AssetPayload, error) {
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

	contentType := normalizeAssetContentType(resp.Header.Get("Content-Type"))
	if !isAllowedAssetContentType(kind, contentType) {
		return nil, ErrAssetUnsupportedType
	}
	if maxSize := s.maxAssetSizeBytes(kind); maxSize > 0 && resp.ContentLength > maxSize {
		return nil, ErrAssetTooLarge
	}

	var buffer bytes.Buffer
	hasher := sha256.New()
	reader := io.TeeReader(resp.Body, hasher)
	limit := s.maxAssetSizeBytes(kind)
	if limit <= 0 {
		limit = 100 * 1024 * 1024
	}
	limited := io.LimitReader(reader, limit+1)
	size, err := io.Copy(&buffer, limited)
	if err != nil {
		return nil, err
	}
	if maxSize := s.maxAssetSizeBytes(kind); maxSize > 0 && size > maxSize {
		return nil, ErrAssetTooLarge
	}

	return s.importAssetBytesForBot(ctx, botID, kind, buffer.Bytes(), path.Base(req.URL.Path), contentType, sourceURL)
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

func isAllowedAssetContentType(kind model.AssetKind, contentType string) bool {
	switch kind {
	case model.AssetKindImage:
		return isAllowedImageContentType(contentType)
	case model.AssetKindAudio:
		return isAllowedAudioContentType(contentType)
	default:
		return false
	}
}

func isAllowedImageContentType(contentType string) bool {
	switch normalizeAssetContentType(contentType) {
	case "image/jpeg", "image/png", "image/webp", "image/gif":
		return true
	default:
		return false
	}
}

func isAllowedAudioContentType(contentType string) bool {
	switch normalizeAssetContentType(contentType) {
	case "audio/aac",
		"audio/amr",
		"audio/m4a",
		"audio/mp4",
		"audio/mpeg",
		"audio/ogg",
		"audio/opus",
		"audio/wav",
		"audio/webm",
		"audio/x-m4a",
		"audio/x-wav",
		"audio/3gpp",
		"audio/3gpp2":
		return true
	default:
		return false
	}
}

func (s *AssetService) importAssetBytesForBot(
	ctx context.Context,
	botID uuid.UUID,
	kind model.AssetKind,
	payload []byte,
	fileName string,
	contentType string,
	sourceURL string,
) (*model.AssetPayload, error) {
	if !s.Enabled() {
		return nil, ErrAssetProviderDisabled
	}
	contentType = normalizeAssetContentType(contentType)
	if !isAllowedAssetContentType(kind, contentType) {
		return nil, ErrAssetUnsupportedType
	}

	size := int64(len(payload))
	if size <= 0 {
		return nil, ErrAssetInvalid
	}
	if maxSize := s.maxAssetSizeBytes(kind); maxSize > 0 && size > maxSize {
		return nil, ErrAssetTooLarge
	}

	normalizedFileName := sanitizeAssetFileName(fileName, kind)
	if normalizedFileName == "" {
		normalizedFileName = fmt.Sprintf("%s%s", botID.String(), fileExtensionForContentType(contentType))
	}

	var width, height int
	if kind == model.AssetKindImage {
		width, height = decodeImageDimensions(payload)
	}
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
		Kind:            kind,
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

func decodeAssetDataURL(value string) (string, []byte, error) {
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
	contentType = normalizeAssetContentType(contentType)

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
	switch normalizeAssetContentType(contentType) {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "audio/aac":
		return ".aac"
	case "audio/amr":
		return ".amr"
	case "audio/m4a", "audio/mp4", "audio/x-m4a":
		return ".m4a"
	case "audio/mpeg":
		return ".mp3"
	case "audio/ogg", "audio/opus":
		return ".ogg"
	case "audio/wav", "audio/x-wav":
		return ".wav"
	case "audio/webm":
		return ".webm"
	case "audio/3gpp":
		return ".3gp"
	case "audio/3gpp2":
		return ".3g2"
	default:
		return ""
	}
}

func sanitizeFileName(fileName string) string {
	return sanitizeAssetFileName(fileName, model.AssetKindImage)
}

func sanitizeAssetFileName(fileName string, kind model.AssetKind) string {
	name := strings.TrimSpace(path.Base(fileName))
	if name == "" || name == "." || name == "/" {
		return string(kind)
	}
	return name
}

func mimeExtensionFromType(contentType string) string {
	return fileExtensionForContentType(contentType)
}

func normalizeAssetContentType(contentType string) string {
	normalized := strings.ToLower(strings.TrimSpace(contentType))
	if before, _, ok := strings.Cut(normalized, ";"); ok {
		normalized = strings.TrimSpace(before)
	}
	return normalized
}

func assetKindForMessageType(contentType string) (model.AssetKind, bool) {
	switch strings.ToLower(strings.TrimSpace(contentType)) {
	case string(model.MsgTypeImage):
		return model.AssetKindImage, true
	case string(model.MsgTypeAudio):
		return model.AssetKindAudio, true
	default:
		return "", false
	}
}

func (s *AssetService) maxAssetSizeBytes(kind model.AssetKind) int64 {
	switch kind {
	case model.AssetKindImage:
		return int64(s.assetCfg.MaxImageSizeMB) * 1024 * 1024
	case model.AssetKindAudio:
		return int64(s.assetCfg.MaxAudioSizeMB) * 1024 * 1024
	default:
		return 0
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
