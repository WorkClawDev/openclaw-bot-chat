package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"time"
)

type AgentApprovalRepository struct{ db *gorm.DB }

func NewAgentApprovalRepository(db *gorm.DB) *AgentApprovalRepository {
	return &AgentApprovalRepository{db: db}
}
func (r *AgentApprovalRepository) Request(ctx context.Context, approval *model.AgentApproval) (*model.AgentApproval, error) {
	err := r.db.WithContext(ctx).Clauses(clause.OnConflict{DoNothing: true}).Create(approval).Error
	if err != nil {
		return nil, err
	}
	var result model.AgentApproval
	err = r.db.WithContext(ctx).Where("owner_id = ? AND bot_id = ? AND run_id = ? AND tool = ? AND parameter_hash = ?", approval.OwnerID, approval.BotID, approval.RunID, approval.Tool, approval.ParameterHash).First(&result).Error
	return &result, err
}
func (r *AgentApprovalRepository) List(ctx context.Context, owner uuid.UUID) ([]model.AgentApproval, error) {
	var rows []model.AgentApproval
	err := r.db.WithContext(ctx).Where("owner_id = ?", owner).Order("created_at DESC").Limit(100).Find(&rows).Error
	return rows, err
}
func (r *AgentApprovalRepository) Get(ctx context.Context, owner, bot, id uuid.UUID) (*model.AgentApproval, error) {
	var row model.AgentApproval
	err := r.db.WithContext(ctx).Where("owner_id = ? AND bot_id = ? AND id = ?", owner, bot, id).First(&row).Error
	return &row, err
}
func (r *AgentApprovalRepository) Decide(ctx context.Context, owner, id uuid.UUID, status string, now time.Time) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentApproval
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ?", id, owner).First(&row).Error; err != nil {
			return err
		}
		if row.Status != "pending" || !row.ExpiresAt.After(now) {
			return gorm.ErrRecordNotFound
		}
		result := tx.Model(&model.AgentApproval{}).Where("id = ? AND owner_id = ? AND status = 'pending'", id, owner).Updates(map[string]interface{}{"status": status, "decided_by": owner, "decided_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return gorm.ErrRecordNotFound
		}
		return nil
	})
}
