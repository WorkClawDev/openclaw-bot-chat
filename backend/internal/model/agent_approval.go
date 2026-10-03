package model

import (
	"github.com/google/uuid"
	"time"
)

type AgentApproval struct {
	ID            uuid.UUID  `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID       uuid.UUID  `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID         uuid.UUID  `gorm:"type:uuid;not null;index" json:"bot_id"`
	RunID         string     `gorm:"not null;index:approval_scope,unique" json:"run_id"`
	Tool          string     `gorm:"not null;index:approval_scope,unique" json:"tool"`
	ParameterHash string     `gorm:"not null;index:approval_scope,unique" json:"parameter_hash"`
	Arguments     JSONMap    `gorm:"type:jsonb" json:"arguments"`
	Status        string     `gorm:"not null" json:"status"`
	ExpiresAt     time.Time  `json:"expires_at"`
	DecidedBy     *uuid.UUID `gorm:"type:uuid" json:"decided_by,omitempty"`
	DecidedAt     *time.Time `json:"decided_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
}
