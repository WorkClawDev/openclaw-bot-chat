package model

import (
	"github.com/google/uuid"
	"time"
)

// PushDevice represents one app installation, not an account-wide preference.
// Revision changes on token, account, environment or enabled-state changes so
// queued notifications cannot follow a device to a different account.
type PushDevice struct {
	ID          uuid.UUID `gorm:"type:uuid;primaryKey" json:"-"`
	UserID      uuid.UUID `gorm:"type:uuid;not null;index" json:"-"`
	Token       string    `gorm:"type:varchar(1024);not null;uniqueIndex:idx_push_token_environment" json:"-"`
	Environment string    `gorm:"type:varchar(16);not null;uniqueIndex:idx_push_token_environment" json:"-"`
	Revision    uuid.UUID `gorm:"type:uuid;not null" json:"-"`
	Language    string    `gorm:"type:varchar(8);not null" json:"-"`
	Enabled     bool      `gorm:"not null" json:"-"`
	ExpiresAt   time.Time `gorm:"not null;index" json:"-"`
	CreatedAt   time.Time `gorm:"not null" json:"-"`
	UpdatedAt   time.Time `gorm:"not null" json:"-"`
}

type PushDelivery struct {
	ID             uuid.UUID  `gorm:"type:uuid;primaryKey"`
	MessageRowID   int64      `gorm:"not null;uniqueIndex:idx_push_message_device"`
	DeviceID       uuid.UUID  `gorm:"type:uuid;not null;uniqueIndex:idx_push_message_device"`
	UserID         uuid.UUID  `gorm:"type:uuid;not null"`
	DeviceRevision uuid.UUID  `gorm:"type:uuid;not null"`
	State          string     `gorm:"type:varchar(16);not null;index:idx_push_due"`
	Attempts       int        `gorm:"not null"`
	NextAttemptAt  time.Time  `gorm:"not null;index:idx_push_due"`
	LeaseID        *uuid.UUID `gorm:"type:uuid"`
	LeaseUntil     *time.Time
	LastReason     string    `gorm:"type:varchar(64);not null"`
	CreatedAt      time.Time `gorm:"not null"`
	UpdatedAt      time.Time `gorm:"not null"`
}
