package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"time"
)

type AgentArtifactRepository struct{ db *gorm.DB }

func NewAgentArtifactRepository(db *gorm.DB) *AgentArtifactRepository {
	return &AgentArtifactRepository{db: db}
}
func (r *AgentArtifactRepository) Find(ctx context.Context, owner, run uuid.UUID, name, hash string) (*model.AgentArtifact, error) {
	var row model.AgentArtifact
	err := agentDB(ctx, r.db).Where("owner_id = ? AND run_id = ? AND file_name = ? AND sha256 = ?", owner, run, name, hash).First(&row).Error
	return &row, err
}
func (r *AgentArtifactRepository) Create(ctx context.Context, row *model.AgentArtifact) error {
	row.ID = uuid.New()
	row.CreatedAt = time.Now().UTC()
	var versions int64
	if err := agentDB(ctx, r.db).Model(&model.AgentArtifact{}).Where("run_id = ? AND file_name = ?", row.RunID, row.FileName).Count(&versions).Error; err != nil {
		return err
	}
	row.Version = int(versions) + 1
	return agentDB(ctx, r.db).Clauses(clause.OnConflict{DoNothing: true}).Create(row).Error
}
func (r *AgentArtifactRepository) List(ctx context.Context, owner, run uuid.UUID) ([]model.AgentArtifact, error) {
	var rows []model.AgentArtifact
	err := agentDB(ctx, r.db).Where("owner_id = ? AND run_id = ?", owner, run).Order("created_at ASC").Find(&rows).Error
	return rows, err
}
func (r *AgentArtifactRepository) Get(ctx context.Context, owner, id uuid.UUID) (*model.AgentArtifact, error) {
	var row model.AgentArtifact
	err := agentDB(ctx, r.db).Where("owner_id = ? AND id = ?", owner, id).First(&row).Error
	return &row, err
}
