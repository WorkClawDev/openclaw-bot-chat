package repository

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

type DocumentRepository struct {
	db *gorm.DB
}

func NewDocumentRepository(db *gorm.DB) *DocumentRepository {
	return &DocumentRepository{db: db}
}

func (r *DocumentRepository) Create(ctx context.Context, document *model.Document) error {
	if document.ID == uuid.Nil {
		document.ID = uuid.New()
	}
	return r.db.WithContext(ctx).Create(document).Error
}

func (r *DocumentRepository) ListByOwner(ctx context.Context, ownerID uuid.UUID, limit int) ([]model.Document, error) {
	var documents []model.Document
	query := r.db.WithContext(ctx).
		Where("owner_id = ? AND status = ?", ownerID, model.DocumentStatusActive)
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	err := query.
		Order("updated_at DESC").
		Limit(limit).
		Find(&documents).Error
	return documents, err
}

func (r *DocumentRepository) GetActiveByIDAndOwner(ctx context.Context, id, ownerID uuid.UUID) (*model.Document, error) {
	var document model.Document
	err := r.db.WithContext(ctx).
		Where("id = ? AND owner_id = ? AND status = ?", id, ownerID, model.DocumentStatusActive).
		First(&document).Error
	if err != nil {
		return nil, err
	}
	return &document, nil
}

func (r *DocumentRepository) Update(ctx context.Context, document *model.Document) error {
	document.UpdatedAt = time.Now()
	return r.db.WithContext(ctx).Save(document).Error
}

func (r *DocumentRepository) Archive(ctx context.Context, id, ownerID uuid.UUID) error {
	result := r.db.WithContext(ctx).Model(&model.Document{}).
		Where("id = ? AND owner_id = ? AND status = ?", id, ownerID, model.DocumentStatusActive).
		Updates(map[string]interface{}{
			"status":     model.DocumentStatusArchived,
			"updated_at": time.Now(),
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
