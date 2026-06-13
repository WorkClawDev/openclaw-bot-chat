package response

import (
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

type BotResponse struct {
	ID             uuid.UUID              `json:"id"`
	OwnerID        uuid.UUID              `json:"owner_id"`
	UserID         uuid.UUID              `json:"userId"`
	Name           string                 `json:"name"`
	Description    *string                `json:"description,omitempty"`
	Avatar         *string                `json:"avatar,omitempty"`
	AvatarURL      *string                `json:"avatar_url,omitempty"`
	BotType        model.BotType          `json:"bot_type"`
	Status         string                 `json:"status"`
	StatusCode     model.BotStatus        `json:"status_code"`
	IsPublic       bool                   `json:"is_public"`
	Config         map[string]interface{} `json:"config,omitempty"`
	MQTTTopic      *string                `json:"mqtt_topic,omitempty"`
	CreatedAt      time.Time              `json:"created_at"`
	CreatedAtAlias time.Time              `json:"createdAt"`
	UpdatedAt      time.Time              `json:"updated_at"`
	UpdatedAtAlias time.Time              `json:"updatedAt"`
	Owner          *UserResponse          `json:"owner,omitempty"`
}

type BotKeyResponse struct {
	ID              uuid.UUID    `json:"id"`
	BotID           uuid.UUID    `json:"bot_id"`
	BotIDAlias      uuid.UUID    `json:"botId"`
	KeyPrefix       string       `json:"key_prefix"`
	Name            *string      `json:"name,omitempty"`
	LastUsedAt      *time.Time   `json:"last_used_at,omitempty"`
	LastUsedAtAlias *time.Time   `json:"lastUsedAt,omitempty"`
	LastUsedIP      *string      `json:"last_used_ip,omitempty"`
	ExpiresAt       *time.Time   `json:"expires_at,omitempty"`
	IsActive        bool         `json:"is_active"`
	Status          string       `json:"status"`
	CreatedAt       time.Time    `json:"created_at"`
	CreatedAtAlias  time.Time    `json:"createdAt"`
	Bot             *BotResponse `json:"bot,omitempty"`
}

type BotBindingResponse struct {
	Token     string       `json:"token,omitempty"`
	BindURL   string       `json:"bind_url,omitempty"`
	ExpiresAt time.Time    `json:"expires_at"`
	Bot       *BotResponse `json:"bot"`
}

func NewBotResponse(bot *model.Bot) *BotResponse {
	if bot == nil {
		return nil
	}

	return &BotResponse{
		ID:             bot.ID,
		OwnerID:        bot.OwnerID,
		UserID:         bot.OwnerID,
		Name:           bot.Name,
		Description:    bot.Description,
		Avatar:         bot.AvatarURL,
		AvatarURL:      bot.AvatarURL,
		BotType:        bot.BotType,
		Status:         botStatusString(bot.Status),
		StatusCode:     bot.Status,
		IsPublic:       bot.IsPublic,
		Config:         copyJSONMap(bot.Config),
		MQTTTopic:      bot.MQTTTopic,
		CreatedAt:      bot.CreatedAt,
		CreatedAtAlias: bot.CreatedAt,
		UpdatedAt:      bot.UpdatedAt,
		UpdatedAtAlias: bot.UpdatedAt,
		Owner:          NewUserResponse(bot.Owner),
	}
}

func NewBotResponses(bots []model.Bot) []BotResponse {
	if len(bots) == 0 {
		return []BotResponse{}
	}

	responses := make([]BotResponse, 0, len(bots))
	for i := range bots {
		responses = append(responses, *NewBotResponse(&bots[i]))
	}
	return responses
}

func NewBotKeyResponse(key *model.BotKey) *BotKeyResponse {
	if key == nil {
		return nil
	}

	return &BotKeyResponse{
		ID:              key.ID,
		BotID:           key.BotID,
		BotIDAlias:      key.BotID,
		KeyPrefix:       key.KeyPrefix,
		Name:            key.Name,
		LastUsedAt:      key.LastUsedAt,
		LastUsedAtAlias: key.LastUsedAt,
		LastUsedIP:      key.LastUsedIP,
		ExpiresAt:       key.ExpiresAt,
		IsActive:        key.IsActive,
		Status:          botKeyStatusString(key.IsActive),
		CreatedAt:       key.CreatedAt,
		CreatedAtAlias:  key.CreatedAt,
		Bot:             NewBotResponse(key.Bot),
	}
}

func NewBotKeyResponses(keys []model.BotKey) []BotKeyResponse {
	if len(keys) == 0 {
		return []BotKeyResponse{}
	}

	responses := make([]BotKeyResponse, 0, len(keys))
	for i := range keys {
		responses = append(responses, *NewBotKeyResponse(&keys[i]))
	}
	return responses
}

func botStatusString(status model.BotStatus) string {
	switch status {
	case model.BotStatusEnabled:
		return "online"
	case model.BotStatusDisabled:
		return "offline"
	default:
		return "error"
	}
}

func botKeyStatusString(active bool) string {
	if active {
		return "active"
	}
	return "revoked"
}
