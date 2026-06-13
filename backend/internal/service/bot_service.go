package service

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/password"
)

var (
	ErrBotNotFound         = errors.New("bot not found")
	ErrBotKeyNotFound      = errors.New("bot key not found")
	ErrNotBotOwner         = errors.New("you are not the owner of this bot")
	ErrKeyExpired          = errors.New("this key has expired")
	ErrKeyRevoked          = errors.New("this key has been revoked")
	ErrBindingTokenInvalid = errors.New("binding token is invalid")
	ErrBindingTokenExpired = errors.New("binding token is expired")
	ErrBindingTokenUsed    = errors.New("binding token has already been used")
)

// BotService handles bot operations
type BotService struct {
	botRepo          *repository.BotRepository
	keyRepo          *repository.BotKeyRepository
	bindingTokenRepo *repository.BotBindingTokenRepository
	auditRepo        *repository.AuditLogRepository
}

// NewBotService creates a new bot service
func NewBotService(botRepo *repository.BotRepository, keyRepo *repository.BotKeyRepository, bindingTokenRepo *repository.BotBindingTokenRepository, auditRepo *repository.AuditLogRepository) *BotService {
	return &BotService{
		botRepo:          botRepo,
		keyRepo:          keyRepo,
		bindingTokenRepo: bindingTokenRepo,
		auditRepo:        auditRepo,
	}
}

// CreateBotRequest represents bot creation request
type CreateBotRequest struct {
	Name        string        `json:"name" binding:"required,min=1,max=128"`
	Description *string       `json:"description"`
	AvatarURL   *string       `json:"avatar_url"`
	BotType     model.BotType `json:"bot_type"`
	IsPublic    bool          `json:"is_public"`
	Config      model.JSONMap `json:"config"`
}

// UpdateBotRequest represents bot update request
type UpdateBotRequest struct {
	Name        *string          `json:"name"`
	Description *string          `json:"description"`
	AvatarURL   *string          `json:"avatar_url"`
	BotType     *model.BotType   `json:"bot_type"`
	Status      *model.BotStatus `json:"status"`
	IsPublic    *bool            `json:"is_public"`
	Config      *model.JSONMap   `json:"config"`
}

// Create creates a new bot
func (s *BotService) Create(ctx context.Context, req CreateBotRequest, ownerID uuid.UUID, ip, userAgent string) (*model.Bot, error) {
	bot := &model.Bot{
		OwnerID:     ownerID,
		Name:        req.Name,
		Description: req.Description,
		AvatarURL:   normalizeOptionalString(req.AvatarURL),
		BotType:     req.BotType,
		Status:      model.BotStatusEnabled,
		IsPublic:    req.IsPublic,
		Config:      req.Config,
	}

	if err := s.botRepo.Create(ctx, bot); err != nil {
		return nil, err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		BotID:        &bot.ID,
		Action:       string(model.AuditActionCreateBot),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(201),
	})
	return bot, nil
}

// GetByID returns a bot by ID
func (s *BotService) GetByID(ctx context.Context, id uuid.UUID) (*model.Bot, error) {
	bot, err := s.botRepo.GetByID(ctx, id)
	if err != nil {
		return nil, ErrBotNotFound
	}
	return bot, nil
}

// ListByOwner returns bots owned by a user
func (s *BotService) ListByOwner(ctx context.Context, ownerID uuid.UUID, page, pageSize int) ([]model.Bot, int64, error) {
	return s.botRepo.ListByOwner(ctx, ownerID, page, pageSize)
}

// Update updates a bot
func (s *BotService) Update(ctx context.Context, botID, ownerID uuid.UUID, req UpdateBotRequest, ip, userAgent string) (*model.Bot, error) {
	bot, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return nil, ErrBotNotFound
	}
	if req.Name != nil {
		bot.Name = *req.Name
	}
	if req.Description != nil {
		bot.Description = req.Description
	}
	if req.AvatarURL != nil {
		bot.AvatarURL = normalizeOptionalString(req.AvatarURL)
	}
	if req.BotType != nil {
		bot.BotType = *req.BotType
	}
	if req.Status != nil {
		bot.Status = *req.Status
	}
	if req.IsPublic != nil {
		bot.IsPublic = *req.IsPublic
	}
	if req.Config != nil {
		bot.Config = *req.Config
	}
	if err := s.botRepo.Update(ctx, bot); err != nil {
		return nil, err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		BotID:        &bot.ID,
		Action:       string(model.AuditActionUpdateBot),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return bot, nil
}

// Delete deletes a bot
func (s *BotService) Delete(ctx context.Context, botID, ownerID uuid.UUID, ip, userAgent string) error {
	_, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return ErrBotNotFound
	}
	if err := s.botRepo.Delete(ctx, botID); err != nil {
		return err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		BotID:        &botID,
		Action:       string(model.AuditActionDeleteBot),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return nil
}

func normalizeOptionalString(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

// --- Bot Keys ---

// CreateKeyRequest represents key creation request
type CreateKeyRequest struct {
	Name      *string `json:"name"`
	ExpiresAt *int64  `json:"expires_at"` // Unix timestamp, 0 = never
}

// BotKeyResponse is returned when creating a key (plaintext shown once)
type BotKeyResponse struct {
	ID        uuid.UUID `json:"id"`
	Key       string    `json:"key"` // plaintext, only shown once
	KeyPrefix string    `json:"key_prefix"`
	Name      *string   `json:"name,omitempty"`
	ExpiresAt *int64    `json:"expires_at,omitempty"`
	CreatedAt int64     `json:"created_at"`
}

// CreateKey creates a new bot key and returns the plaintext (only time it's shown)
func (s *BotService) CreateKey(ctx context.Context, botID, ownerID uuid.UUID, req CreateKeyRequest, ip, userAgent string) (*BotKeyResponse, error) {
	_, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return nil, ErrBotNotFound
	}

	rawKey := generateBotKey()
	prefix := rawKey[:12]
	hashedKey, err := password.Hash(rawKey)
	if err != nil {
		return nil, err
	}

	key := &model.BotKey{
		BotID:     botID,
		KeyPrefix: prefix,
		KeyHash:   hashedKey,
		Name:      req.Name,
		IsActive:  true,
	}

	if req.ExpiresAt != nil && *req.ExpiresAt > 0 {
		t := time.Unix(*req.ExpiresAt, 0)
		key.ExpiresAt = &t
	}

	if err := s.keyRepo.Create(ctx, key); err != nil {
		return nil, err
	}

	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		BotID:        &botID,
		Action:       string(model.AuditActionCreateKey),
		ResourceType: strPtr("bot_key"),
		ResourceID:   &key.ID,
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(201),
	})

	resp := &BotKeyResponse{
		ID:        key.ID,
		Key:       rawKey,
		KeyPrefix: prefix,
		Name:      key.Name,
		CreatedAt: key.CreatedAt.Unix(),
	}
	if key.ExpiresAt != nil {
		exp := key.ExpiresAt.Unix()
		resp.ExpiresAt = &exp
	}
	return resp, nil
}

// ListKeys returns all keys for a bot
func (s *BotService) ListKeys(ctx context.Context, botID, ownerID uuid.UUID) ([]model.BotKey, error) {
	_, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return nil, ErrBotNotFound
	}
	return s.keyRepo.ListByBotID(ctx, botID)
}

// RevokeKey revokes a bot key
func (s *BotService) RevokeKey(ctx context.Context, botID, keyID, ownerID uuid.UUID, ip, userAgent string) error {
	_, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return ErrBotNotFound
	}
	key, err := s.keyRepo.GetByID(ctx, keyID)
	if err != nil {
		return ErrBotKeyNotFound
	}
	if key.BotID != botID {
		return ErrBotKeyNotFound
	}
	if err := s.keyRepo.Revoke(ctx, keyID); err != nil {
		return err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		BotID:        &botID,
		Action:       string(model.AuditActionRevokeKey),
		ResourceType: strPtr("bot_key"),
		ResourceID:   &keyID,
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return nil
}

// ValidateKey validates a bot key and returns the bot if valid
func (s *BotService) ValidateKey(ctx context.Context, rawKey string) (*model.Bot, error) {
	if len(rawKey) < 12 {
		return nil, ErrInvalidCredentials
	}
	prefix := rawKey[:12]
	key, err := s.keyRepo.GetByPrefix(ctx, prefix)
	if err != nil {
		return nil, ErrInvalidCredentials
	}
	if !key.IsActive {
		return nil, ErrKeyRevoked
	}
	if key.ExpiresAt != nil && key.ExpiresAt.Before(time.Now()) {
		return nil, ErrKeyExpired
	}
	if !password.Check(rawKey, key.KeyHash) {
		return nil, ErrInvalidCredentials
	}
	_ = s.keyRepo.UpdateLastUsed(ctx, key.ID, "")
	bot, err := s.botRepo.GetByID(ctx, key.BotID)
	if err != nil {
		return nil, ErrBotNotFound
	}
	return bot, nil
}

// generateBotKey generates a bot key: ocbk_{32 base64url safe}_{8 char uuid}
func generateBotKey() string {
	bytes := make([]byte, 24)
	_, _ = rand.Read(bytes)
	encoded := base64.URLEncoding.EncodeToString(bytes)
	encoded = encoded[:32]
	// Replace URL-unsafe chars for readability
	for i, c := range encoded {
		if c == '+' {
			encoded = encoded[:i] + "P" + encoded[i+1:]
		} else if c == '/' {
			encoded = encoded[:i] + "Q" + encoded[i+1:]
		}
	}
	shortID := uuid.New().String()[:8]
	return fmt.Sprintf("ocbk_%s_%s", encoded, shortID)
}

func strPtr(s string) *string { return &s }

// --- Bot Bindings ---

const defaultBotBindingTTL = 15 * time.Minute

type BotBindingTokenResponse struct {
	ID          uuid.UUID  `json:"id"`
	Token       string     `json:"token"`
	TokenPrefix string     `json:"token_prefix"`
	Bot         *model.Bot `json:"bot"`
	ExpiresAt   time.Time  `json:"expires_at"`
}

func (s *BotService) CreateBindingToken(ctx context.Context, botID, ownerID uuid.UUID) (*BotBindingTokenResponse, error) {
	bot, err := s.botRepo.GetByIDAndOwner(ctx, botID, ownerID)
	if err != nil {
		return nil, ErrBotNotFound
	}

	rawToken := generateBotBindingToken()
	prefix := rawToken[:14]
	hashedToken, err := password.Hash(rawToken)
	if err != nil {
		return nil, err
	}

	expiresAt := time.Now().Add(defaultBotBindingTTL)
	token := &model.BotBindingToken{
		BotID:     botID,
		OwnerID:   ownerID,
		Prefix:    prefix,
		TokenHash: hashedToken,
		ExpiresAt: expiresAt,
	}
	if err := s.bindingTokenRepo.Create(ctx, token); err != nil {
		return nil, err
	}

	return &BotBindingTokenResponse{
		ID:          token.ID,
		Token:       rawToken,
		TokenPrefix: prefix,
		Bot:         bot,
		ExpiresAt:   expiresAt,
	}, nil
}

func (s *BotService) PreviewBindingToken(ctx context.Context, rawToken string, userID uuid.UUID) (*model.Bot, *model.BotBindingToken, error) {
	token, err := s.validateBindingToken(ctx, rawToken, userID)
	if err != nil {
		return nil, nil, err
	}
	if token.Bot == nil {
		bot, err := s.botRepo.GetByID(ctx, token.BotID)
		if err != nil {
			return nil, nil, ErrBotNotFound
		}
		token.Bot = bot
	}
	return token.Bot, token, nil
}

func (s *BotService) ConfirmBindingToken(ctx context.Context, rawToken string, userID uuid.UUID) (*model.Bot, error) {
	bot, token, err := s.PreviewBindingToken(ctx, rawToken, userID)
	if err != nil {
		return nil, err
	}
	used, err := s.bindingTokenRepo.MarkUsed(ctx, token.Prefix, time.Now())
	if err != nil {
		return nil, err
	}
	if !used {
		return nil, ErrBindingTokenUsed
	}
	return bot, nil
}

func (s *BotService) validateBindingToken(ctx context.Context, rawToken string, userID uuid.UUID) (*model.BotBindingToken, error) {
	rawToken = strings.TrimSpace(rawToken)
	if len(rawToken) < 14 {
		return nil, ErrBindingTokenInvalid
	}
	prefix := rawToken[:14]
	token, err := s.bindingTokenRepo.GetByPrefix(ctx, prefix)
	if err != nil {
		return nil, ErrBindingTokenInvalid
	}
	if token.OwnerID != userID {
		return nil, ErrBindingTokenInvalid
	}
	if token.UsedAt != nil {
		return nil, ErrBindingTokenUsed
	}
	if time.Now().After(token.ExpiresAt) {
		return nil, ErrBindingTokenExpired
	}
	if !password.Check(rawToken, token.TokenHash) {
		return nil, ErrBindingTokenInvalid
	}
	return token, nil
}

func generateBotBindingToken() string {
	bytes := make([]byte, 24)
	_, _ = rand.Read(bytes)
	encoded := base64.RawURLEncoding.EncodeToString(bytes)
	shortID := uuid.NewString()[:8]
	return fmt.Sprintf("ocbb_%s_%s", encoded, shortID)
}
