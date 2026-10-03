package model

import (
	"github.com/google/uuid"
	"time"
)

type AgentRun struct {
	ID              uuid.UUID  `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID         uuid.UUID  `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID           uuid.UUID  `gorm:"type:uuid;not null;uniqueIndex:agent_run_trigger" json:"bot_id"`
	TriggerKey      string     `gorm:"not null;uniqueIndex:agent_run_trigger" json:"trigger_key"`
	TaskID          *uuid.UUID `gorm:"type:uuid;index" json:"task_id,omitempty"`
	Conversation    string     `json:"conversation"`
	Attempt         int        `json:"attempt"`
	Status          string     `gorm:"not null;index" json:"status"`
	WorkerID        string     `json:"worker_id"`
	LeaseUntil      int64      `json:"lease_until"`
	Fence           int64      `json:"fence"`
	CancelRequested bool       `json:"cancel_requested"`
	EventSeq        int64      `json:"event_seq"`
	Steps           int        `json:"steps"`
	MaxSteps        int        `json:"max_steps"`
	Input           JSONMap    `gorm:"type:jsonb" json:"input"`
	Result          JSONMap    `gorm:"type:jsonb" json:"result"`
	Error           string     `json:"error,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}
type AgentRunEvent struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	RunID     uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:agent_event_seq" json:"run_id"`
	Seq       int64     `gorm:"not null;uniqueIndex:agent_event_seq" json:"seq"`
	Type      string    `json:"type"`
	Data      JSONMap   `gorm:"type:jsonb" json:"data"`
	CreatedAt time.Time `json:"created_at"`
}
