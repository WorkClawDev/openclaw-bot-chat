package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

// MessageRepository handles message database operations
type MessageRepository struct {
	db             *gorm.DB
	messageCreated func(context.Context, *gorm.DB, *model.Message) error
}

// SetMessageCreatedHook installs a transactional outbox hook before MQTT starts.
func (r *MessageRepository) SetMessageCreatedHook(hook func(context.Context, *gorm.DB, *model.Message) error) {
	r.messageCreated = hook
}

func NewMessageRepository(db *gorm.DB) *MessageRepository {
	return &MessageRepository{db: db}
}

func (r *MessageRepository) withDB(db *gorm.DB) *MessageRepository {
	return &MessageRepository{db: db}
}

func (r *MessageRepository) Create(ctx context.Context, msg *model.Message) error {
	return r.db.WithContext(ctx).Create(msg).Error
}

func (r *MessageRepository) GetByID(ctx context.Context, id int64) (*model.Message, error) {
	var msg model.Message
	err := r.db.WithContext(ctx).Where("id = ?", id).First(&msg).Error
	if err != nil {
		return nil, err
	}
	return &msg, nil
}

func (r *MessageRepository) GetByConversationID(ctx context.Context, conversationID string, limit int, beforeSeq int64) ([]model.Message, error) {
	var msgs []model.Message
	query := r.db.WithContext(ctx).Where("conversation_id = ? AND is_deleted = false", conversationID)
	if beforeSeq > 0 {
		query = query.Where("seq < ?", beforeSeq)
	}
	err := query.Order("seq DESC").Limit(limit).Find(&msgs).Error
	// Reverse to get chronological order
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}
	return msgs, err
}

func (r *MessageRepository) GetByConversationIDAfterSeq(ctx context.Context, conversationID string, limit int, afterSeq int64) ([]model.Message, error) {
	var msgs []model.Message
	query := r.db.WithContext(ctx).Where("conversation_id = ? AND is_deleted = false", conversationID)
	if afterSeq > 0 {
		query = query.Where("seq > ?", afterSeq)
	}
	err := query.Order("seq ASC").Limit(limit).Find(&msgs).Error
	return msgs, err
}

func (r *MessageRepository) ExistsByConversationAndMessageID(ctx context.Context, conversationID string, messageID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.Message{}).
		Where("conversation_id = ? AND message_id = ? AND is_deleted = false", conversationID, messageID).
		Count(&count).Error
	return count > 0, err
}

func (r *MessageRepository) CountByConversationID(ctx context.Context, conversationID string) (int64, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.Message{}).Where("conversation_id = ? AND is_deleted = false", conversationID).Count(&count).Error
	return count, err
}

func (r *MessageRepository) GetNextSeq(ctx context.Context, conversationID string) (int64, error) {
	var current struct {
		Seq int64
	}
	result := r.db.WithContext(ctx).
		Raw("SELECT seq FROM messages WHERE conversation_id = ? ORDER BY seq DESC LIMIT 1 FOR UPDATE", conversationID).
		Scan(&current)
	if result.Error != nil {
		return 0, result.Error
	}
	if result.RowsAffected == 0 {
		return 1, nil
	}
	return current.Seq + 1, nil
}

func (r *MessageRepository) CreateWithNextSeq(ctx context.Context, msg *model.Message) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		scoped := r.withDB(tx)
		if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext(?))", msg.ConversationID).Error; err != nil {
			return err
		}

		exists, err := scoped.ExistsByConversationAndMessageID(ctx, msg.ConversationID, msg.MessageID)
		if err != nil {
			return err
		}
		if exists {
			return nil
		}

		seq, err := scoped.GetNextSeq(ctx, msg.ConversationID)
		if err != nil {
			return err
		}
		msg.Seq = seq
		if err := scoped.Create(ctx, msg); err != nil {
			return err
		}
		if r.messageCreated != nil {
			return r.messageCreated(ctx, tx, msg)
		}
		return nil
	})
}

func (r *MessageRepository) GetConversations(ctx context.Context, userID uuid.UUID, botID *uuid.UUID, limit int) ([]string, error) {
	var conversationIDs []string
	query := r.db.WithContext(ctx).Model(&model.Message{}).
		Select("conversation_id").
		Where("is_deleted = false")

	if botID != nil {
		query = query.Where("(sender_id = ? OR bot_id = ?)", userID, *botID)
	} else {
		query = query.Where("sender_id = ? OR bot_id IN (SELECT id FROM bots WHERE owner_id = ?)", userID, userID)
	}

	err := query.
		Group("conversation_id").
		Order("MAX(created_at) DESC").
		Limit(limit).
		Pluck("conversation_id", &conversationIDs).Error
	return conversationIDs, err
}

func (r *MessageRepository) GetConversationsForBot(ctx context.Context, botID uuid.UUID, limit int) ([]string, error) {
	var conversationIDs []string
	err := r.db.WithContext(ctx).Model(&model.Message{}).
		Select("conversation_id").
		Where(
			`is_deleted = false AND (
				bot_id = ? OR
				group_id IN (
					SELECT group_id
					FROM bot_group_members
					WHERE bot_id = ? AND is_active = true
				)
			)`,
			botID,
			botID,
		).
		Group("conversation_id").
		Order("MAX(created_at) DESC").
		Limit(limit).
		Pluck("conversation_id", &conversationIDs).Error
	return conversationIDs, err
}

func (r *MessageRepository) MarkAsRead(ctx context.Context, conversationID string) error {
	return r.db.WithContext(ctx).Model(&model.Message{}).
		Where("conversation_id = ? AND is_read = false", conversationID).
		Update("is_read", true).Error
}
