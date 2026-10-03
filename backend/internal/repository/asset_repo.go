package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

type AssetRepository struct {
	db *gorm.DB
}

func NewAssetRepository(db *gorm.DB) *AssetRepository {
	return &AssetRepository{db: db}
}

func (r *AssetRepository) Create(ctx context.Context, asset *model.Asset) error {
	return agentDB(ctx, r.db).Create(asset).Error
}

func (r *AssetRepository) Update(ctx context.Context, asset *model.Asset) error {
	return agentDB(ctx, r.db).Save(asset).Error
}

func (r *AssetRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Asset, error) {
	var asset model.Asset
	if err := agentDB(ctx, r.db).Where("id = ?", id).First(&asset).Error; err != nil {
		return nil, err
	}
	return &asset, nil
}

func (r *AssetRepository) GetByObjectKey(ctx context.Context, objectKey string) (*model.Asset, error) {
	var asset model.Asset
	if err := agentDB(ctx, r.db).Where("object_key = ?", objectKey).First(&asset).Error; err != nil {
		return nil, err
	}
	return &asset, nil
}
