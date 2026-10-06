package repository

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"gorm.io/gorm/logger"
)

type PushRepository struct{ db *gorm.DB }

func NewPushRepository(db *gorm.DB) *PushRepository { return &PushRepository{db: db} }

var ErrInvalidPushDevice = errors.New("invalid push device")

func (r *PushRepository) Register(ctx context.Context, device model.PushDevice, now time.Time) error {
	device.Token = strings.ToLower(strings.TrimSpace(device.Token))
	_, err := hex.DecodeString(device.Token)
	if err != nil || len(device.Token) < 2 || len(device.Token) > 1024 || device.ID == uuid.Nil || device.UserID == uuid.Nil || (device.Environment != "sandbox" && device.Environment != "production") || (device.Language != "en" && device.Language != "zh") {
		return ErrInvalidPushDevice
	}
	// GORM's interpolated SQL error logging would expose the device token.
	return r.db.WithContext(ctx).Session(&gorm.Session{Logger: logger.Default.LogMode(logger.Silent)}).Transaction(func(tx *gorm.DB) error {
		// Serialize concurrent re-registration of a token or installation. This
		// also handles reinstall/account-switch without duplicate destinations.
		if tx.Dialector.Name() == "postgres" {
			if err := tx.Exec("SELECT pg_advisory_xact_lock(74105931)").Error; err != nil {
				return err
			}
		}
		var old model.PushDevice
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ?", device.ID).First(&old).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		device.Revision = uuid.New()
		device.CreatedAt = now
		if err == nil {
			device.CreatedAt = old.CreatedAt
			if old.UserID == device.UserID && old.Token == device.Token && old.Environment == device.Environment && old.Enabled == device.Enabled {
				device.Revision = old.Revision
			}
		}
		device.UpdatedAt, device.ExpiresAt = now, now.Add(30*24*time.Hour)
		if err := tx.Where("token = ? AND environment = ? AND id <> ?", device.Token, device.Environment, device.ID).Delete(&model.PushDevice{}).Error; err != nil {
			return err
		}
		return tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "id"}}, UpdateAll: true}).Create(&device).Error
	})
}

func (r *PushRepository) Disable(ctx context.Context, userID, deviceID uuid.UUID, now time.Time) error {
	return r.db.WithContext(ctx).Model(&model.PushDevice{}).Where("id = ? AND user_id = ?", deviceID, userID).
		Updates(map[string]any{"enabled": false, "revision": uuid.New(), "updated_at": now}).Error
}

// EligibleRecipients deliberately handles only messages from a live bot to a
// direct human recipient or current group members. User/system messages and
// bot-to-bot routes must not create notifications for bot owners.
func (r *PushRepository) EligibleRecipients(ctx context.Context, msg *model.Message) ([]uuid.UUID, error) {
	if msg.SenderType != model.SenderTypeBot || msg.SenderID == nil || msg.IsDeleted {
		return nil, nil
	}
	tx := r.db.WithContext(ctx)
	var bot model.Bot
	err := tx.Where("id = ? AND status = ?", *msg.SenderID, model.BotStatusEnabled).First(&bot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p := strings.Split(msg.ConversationID, "/")
	var recipients []uuid.UUID
	if len(p) == 6 && p[0] == "chat" && p[1] == "dm" {
		var user string
		if p[2] == "bot" && p[3] == bot.ID.String() && p[4] == "user" {
			user = p[5]
		}
		if p[4] == "bot" && p[5] == bot.ID.String() && p[2] == "user" {
			user = p[3]
		}
		id, err := uuid.Parse(user)
		if err != nil {
			return nil, nil
		}
		recipients = []uuid.UUID{id}
	} else if len(p) == 3 && p[0] == "chat" && p[1] == "group" {
		groupID, err := uuid.Parse(p[2])
		if err != nil {
			return nil, nil
		}
		var group model.Group
		err = tx.Where("id = ? AND is_active = true", groupID).First(&group).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		var membership int64
		if err := tx.Model(&model.BotGroupMember{}).Where("group_id = ? AND bot_id = ? AND is_active = true", groupID, bot.ID).Count(&membership).Error; err != nil {
			return nil, err
		}
		if membership == 0 {
			return nil, nil
		}
		if err := tx.Model(&model.GroupMember{}).Where("group_id = ? AND is_active = true", groupID).Pluck("user_id", &recipients).Error; err != nil {
			return nil, err
		}
		recipients = append(recipients, group.OwnerID)
	} else {
		return nil, nil
	}
	var active []uuid.UUID
	err = tx.Model(&model.User{}).Where("id IN ? AND status = ? AND is_deleted = false", recipients, model.UserStatusActive).Pluck("id", &active).Error
	return active, err
}

// EnqueueMessage is called with the message transaction after its first insert.
func EnqueueChatPush(ctx context.Context, tx *gorm.DB, msg *model.Message) error {
	now := time.Now().UTC()
	recipients, err := NewPushRepository(tx).EligibleRecipients(ctx, msg)
	if err != nil || len(recipients) == 0 {
		return err
	}
	var devices []model.PushDevice
	if err := tx.WithContext(ctx).Where("user_id IN ? AND enabled = true AND expires_at > ?", recipients, now).Find(&devices).Error; err != nil {
		return err
	}
	for _, device := range devices {
		row := model.PushDelivery{ID: uuid.New(), MessageRowID: msg.ID, DeviceID: device.ID, UserID: device.UserID, DeviceRevision: device.Revision, State: "pending", NextAttemptAt: now, CreatedAt: now, UpdatedAt: now}
		if err := tx.WithContext(ctx).Clauses(clause.OnConflict{DoNothing: true}).Create(&row).Error; err != nil {
			return err
		}
	}
	return nil
}

func (r *PushRepository) Claim(ctx context.Context, now time.Time) (*model.PushDelivery, error) {
	var row model.PushDelivery
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		err := tx.Clauses(clause.Locking{Strength: "UPDATE", Options: "SKIP LOCKED"}).
			Where("state = 'pending' AND next_attempt_at <= ? AND (lease_until IS NULL OR lease_until <= ?)", now, now).
			Order("created_at ASC").First(&row).Error
		if err != nil {
			return err
		}
		lease, until := uuid.New(), now.Add(time.Minute)
		row.LeaseID, row.LeaseUntil = &lease, &until
		row.Attempts++
		return tx.Model(&model.PushDelivery{}).Where("id = ?", row.ID).Updates(map[string]any{"lease_id": lease, "lease_until": until, "attempts": row.Attempts, "updated_at": now}).Error
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	return &row, err
}

func (r *PushRepository) Destination(ctx context.Context, row *model.PushDelivery, now time.Time) (*model.PushDevice, *model.Message, error) {
	var device model.PushDevice
	err := r.db.WithContext(ctx).Where("id = ? AND user_id = ? AND revision = ? AND enabled = true AND expires_at > ?", row.DeviceID, row.UserID, row.DeviceRevision, now).First(&device).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	var msg model.Message
	err = r.db.WithContext(ctx).Where("id = ? AND is_deleted = false", row.MessageRowID).First(&msg).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	recipients, err := r.EligibleRecipients(ctx, &msg)
	if err != nil {
		return nil, nil, err
	}
	for _, id := range recipients {
		if id == row.UserID {
			return &device, &msg, nil
		}
	}
	return nil, nil, nil
}

func (r *PushRepository) Finish(ctx context.Context, row *model.PushDelivery, state, reason string, next time.Time) error {
	return r.db.WithContext(ctx).Model(&model.PushDelivery{}).Where("id = ? AND lease_id = ?", row.ID, row.LeaseID).
		Updates(map[string]any{"state": state, "last_reason": reason, "next_attempt_at": next, "lease_id": nil, "lease_until": nil, "updated_at": time.Now().UTC()}).Error
}

func (r *PushRepository) Invalidate(ctx context.Context, device *model.PushDevice, invalidSince *time.Time) error {
	q := r.db.WithContext(ctx).Model(&model.PushDevice{}).Where("id = ? AND revision = ?", device.ID, device.Revision)
	if invalidSince != nil {
		q = q.Where("updated_at <= ?", *invalidSince)
	}
	return q.Updates(map[string]any{"enabled": false, "revision": uuid.New(), "updated_at": time.Now().UTC()}).Error
}

func (r *PushRepository) Prune(ctx context.Context, now time.Time) error {
	// Terminal deliveries contain routing identifiers only, never message text.
	return r.db.WithContext(ctx).Where("state <> 'pending' AND updated_at < ?", now.Add(-7*24*time.Hour)).Delete(&model.PushDelivery{}).Error
}
