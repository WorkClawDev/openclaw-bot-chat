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

// Public image redirects are only for an image its owner has chosen as an
// avatar. Merely copying someone else's asset URL into a profile cannot publish
// their private message attachment.
func (r *AssetRepository) IsPublicAvatar(ctx context.Context, asset *model.Asset) (bool, error) {
	if asset.Kind != model.AssetKindImage || asset.OwnerUserID == nil {
		return false, nil
	}
	db := agentDB(ctx, r.db)
	var active int64
	if err := db.Model(&model.User{}).Where("id = ? AND status = ? AND is_deleted = false", asset.OwnerUserID, model.UserStatusActive).Count(&active).Error; err != nil || active != 1 {
		return false, err
	}
	pattern := "%/api/v1/assets/image/" + asset.ID.String()
	queries := []*gorm.DB{
		db.Model(&model.User{}).Where("id = ? AND avatar_url LIKE ?", asset.OwnerUserID, pattern),
		db.Model(&model.Bot{}).Where("owner_id = ? AND status = ? AND avatar_url LIKE ?", asset.OwnerUserID, model.BotStatusEnabled, pattern),
		db.Model(&model.Group{}).Where("owner_id = ? AND is_active = true AND avatar_url LIKE ?", asset.OwnerUserID, pattern),
	}
	for _, query := range queries {
		var count int64
		if err := query.Count(&count).Error; err != nil {
			return false, err
		}
		if count > 0 {
			return true, nil
		}
	}
	return false, nil
}
