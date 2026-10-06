package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

// BotRepository handles bot database operations
type BotRepository struct {
	db *gorm.DB
}

func NewBotRepository(db *gorm.DB) *BotRepository {
	return &BotRepository{db: db}
}

func (r *BotRepository) Create(ctx context.Context, bot *model.Bot) error {
	return r.db.WithContext(ctx).Create(bot).Error
}

func (r *BotRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Bot, error) {
	var bot model.Bot
	err := r.db.WithContext(ctx).Preload("Owner").Where("id = ?", id).First(&bot).Error
	if err != nil {
		return nil, err
	}
	return &bot, nil
}

func (r *BotRepository) GetByIDAndOwner(ctx context.Context, id, ownerID uuid.UUID) (*model.Bot, error) {
	var bot model.Bot
	err := r.db.WithContext(ctx).Where("id = ? AND owner_id = ?", id, ownerID).First(&bot).Error
	if err != nil {
		return nil, err
	}
	return &bot, nil
}

func (r *BotRepository) ListByOwner(ctx context.Context, ownerID uuid.UUID, page, pageSize int) ([]model.Bot, int64, error) {
	var bots []model.Bot
	var total int64

	query := r.db.WithContext(ctx).Model(&model.Bot{}).Where("owner_id = ?", ownerID)
	if err := query.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	offset := (page - 1) * pageSize
	if err := query.Preload("Owner").Order("created_at DESC").Offset(offset).Limit(pageSize).Find(&bots).Error; err != nil {
		return nil, 0, err
	}
	return bots, total, nil
}

func (r *BotRepository) Update(ctx context.Context, bot *model.Bot) error {
	return r.db.WithContext(ctx).Save(bot).Error
}

func (r *BotRepository) Delete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).Delete(&model.Bot{}, "id = ?", id).Error
}

func (r *BotRepository) GetByMQTTTopic(ctx context.Context, topic string) (*model.Bot, error) {
	var bot model.Bot
	err := r.db.WithContext(ctx).Where("mqtt_topic = ?", topic).First(&bot).Error
	if err != nil {
		return nil, err
	}
	return &bot, nil
}

func (r *BotRepository) HardDelete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).Unscoped().Delete(&model.Bot{}, "id = ?", id).Error
}
