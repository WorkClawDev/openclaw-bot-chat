package model

import (
	"github.com/google/uuid"
	"time"
)

type AgentMemory struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID   uuid.UUID `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID     uuid.UUID `gorm:"type:uuid;not null;index" json:"bot_id"`
	Scope     string    `json:"scope"`
	Content   string    `json:"content"`
	Source    string    `json:"source"`
	Confirmed bool      `json:"confirmed"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
type AgentMemoryRevision struct {
	BotID    uuid.UUID `gorm:"type:uuid;primaryKey"`
	Revision int64
}
type AgentSchedule struct {
	ID             uuid.UUID  `gorm:"type:uuid;primaryKey" json:"id"`
	OwnerID        uuid.UUID  `gorm:"type:uuid;not null;index" json:"owner_id"`
	BotID          uuid.UUID  `gorm:"type:uuid;not null" json:"bot_id"`
	Title          string     `json:"title"`
	Prompt         string     `json:"prompt"`
	Timezone       string     `json:"timezone"`
	Recurrence     string     `json:"recurrence"`
	MissedPolicy   string     `json:"missed_policy"`
	Status         string     `json:"status"`
	NextAt         time.Time  `gorm:"index" json:"next_at"`
	LastTaskStatus string     `gorm:"-" json:"last_task_status,omitempty"`
	LastTaskNote   *string    `gorm:"-" json:"last_task_note,omitempty"`
	LastTaskID     *uuid.UUID `gorm:"type:uuid" json:"last_task_id,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}
type AgentScheduleOccurrence struct {
	ID         uuid.UUID  `gorm:"type:uuid;primaryKey" json:"id"`
	ScheduleID uuid.UUID  `gorm:"type:uuid;not null;uniqueIndex:schedule_occurrence" json:"schedule_id"`
	At         time.Time  `gorm:"not null;uniqueIndex:schedule_occurrence" json:"at"`
	TaskID     *uuid.UUID `gorm:"type:uuid" json:"task_id,omitempty"`
	Status     string     `json:"status"`
	CreatedAt  time.Time  `json:"created_at"`
}
