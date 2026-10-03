package model

import (
	"github.com/google/uuid"
	"time"
)

type AgentInbox struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID   uuid.UUID `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID     uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:agent_inbox_key" json:"bot_id"`
	MessageID string    `gorm:"not null;uniqueIndex:agent_inbox_key" json:"message_id"`
	Message   JSONMap   `gorm:"type:jsonb;not null" json:"message"`
	Status    string    `gorm:"not null;index" json:"status"`
	Response  JSONMap   `gorm:"type:jsonb" json:"response"`
	Delivered bool      `gorm:"not null;default:false" json:"delivered"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
type AgentContext struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID   uuid.UUID `gorm:"type:uuid;not null" json:"owner_id"`
	BotID     uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:agent_context_key" json:"bot_id"`
	Scope     string    `gorm:"not null;uniqueIndex:agent_context_key" json:"scope"`
	Data      JSONMap   `gorm:"type:jsonb" json:"data"`
	UpdatedAt time.Time `json:"updated_at"`
}
type AgentToolCall struct {
	ID         uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID    uuid.UUID `gorm:"type:uuid;not null" json:"owner_id"`
	BotID      uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:agent_tool_key" json:"bot_id"`
	RunID      string    `gorm:"not null;uniqueIndex:agent_tool_key" json:"run_id"`
	Key        string    `gorm:"not null;uniqueIndex:agent_tool_key" json:"key"`
	Tool       string    `json:"tool"`
	Idempotent bool      `json:"idempotent"`
	Status     string    `json:"status"`
	Result     JSONMap   `gorm:"type:jsonb" json:"result"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}
