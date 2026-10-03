package model

import (
	"github.com/google/uuid"
	"time"
)

type AgentArtifact struct {
	ID         uuid.UUID  `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID    uuid.UUID  `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID      uuid.UUID  `gorm:"type:uuid;not null" json:"bot_id"`
	RunID      uuid.UUID  `gorm:"type:uuid;not null;uniqueIndex:artifact_content" json:"run_id"`
	TaskID     *uuid.UUID `gorm:"type:uuid" json:"task_id,omitempty"`
	AssetID    uuid.UUID  `gorm:"type:uuid;not null" json:"asset_id"`
	DocumentID *uuid.UUID `gorm:"type:uuid" json:"document_id,omitempty"`
	FileName   string     `gorm:"not null;uniqueIndex:artifact_content" json:"file_name"`
	MIMEType   string     `json:"mime_type"`
	SHA256     string     `gorm:"not null;uniqueIndex:artifact_content" json:"sha256"`
	Size       int64      `json:"size"`
	Version    int        `json:"version"`
	CreatedAt  time.Time  `json:"created_at"`
}
