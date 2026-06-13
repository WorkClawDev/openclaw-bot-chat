package repository

import (
	"context"
	"time"

	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

// BotBindingTokenRepository handles one-time iOS binding token persistence.
type BotBindingTokenRepository struct {
	db *gorm.DB
}

func NewBotBindingTokenRepository(db *gorm.DB) *BotBindingTokenRepository {
	return &BotBindingTokenRepository{db: db}
}

func (r *BotBindingTokenRepository) Create(ctx context.Context, token *model.BotBindingToken) error {
	return r.db.WithContext(ctx).Create(token).Error
}

func (r *BotBindingTokenRepository) GetByPrefix(ctx context.Context, prefix string) (*model.BotBindingToken, error) {
	var token model.BotBindingToken
	err := r.db.WithContext(ctx).Preload("Bot").Where("prefix = ?", prefix).First(&token).Error
	if err != nil {
		return nil, err
	}
	return &token, nil
}

func (r *BotBindingTokenRepository) MarkUsed(ctx context.Context, prefix string, usedAt time.Time) (bool, error) {
	result := r.db.WithContext(ctx).
		Model(&model.BotBindingToken{}).
		Where("prefix = ? AND used_at IS NULL", prefix).
		Update("used_at", usedAt)
	if result.Error != nil {
		return false, result.Error
	}
	return result.RowsAffected == 1, nil
}
