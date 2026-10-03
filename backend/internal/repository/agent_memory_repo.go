package repository

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"strings"
	"time"
)

type AgentMemoryRepository struct{ db *gorm.DB }

func NewAgentMemoryRepository(db *gorm.DB) *AgentMemoryRepository { return &AgentMemoryRepository{db} }
func (r *AgentMemoryRepository) List(ctx context.Context, owner uuid.UUID, bot *uuid.UUID, scope string) ([]model.AgentMemory, error) {
	rows := []model.AgentMemory{}
	q := agentDB(ctx, r.db).Where("owner_id = ?", owner)
	if bot != nil {
		q = q.Where("bot_id = ?", *bot)
	}
	if scope != "" {
		q = q.Where("scope IN ?", []string{scope, "personal"})
	}
	err := q.Where("confirmed = ?", true).Order("created_at ASC").Limit(500).Find(&rows).Error
	return rows, err
}
func (r *AgentMemoryRepository) Revision(ctx context.Context, bot uuid.UUID) (int64, error) {
	var row model.AgentMemoryRevision
	err := agentDB(ctx, r.db).Where("bot_id = ?", bot).First(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return 0, nil
	}
	return row.Revision, err
}
func (r *AgentMemoryRepository) Save(ctx context.Context, owner uuid.UUID, row *model.AgentMemory) error {
	if len(strings.TrimSpace(row.Content)) == 0 || len(row.Content) > 4000 || len(row.Source) > 256 || len(row.Scope) > 128 || !row.Confirmed {
		return errors.New("invalid confirmed memory")
	}
	return agentDB(ctx, r.db).Transaction(func(tx *gorm.DB) error {
		var bot model.Bot
		if err := tx.Where("id = ? AND owner_id = ?", row.BotID, owner).First(&bot).Error; err != nil {
			return err
		}
		if row.ID != uuid.Nil {
			var existing model.AgentMemory
			if err := tx.Where("id = ? AND owner_id = ? AND bot_id = ?", row.ID, owner, row.BotID).First(&existing).Error; err != nil {
				return err
			}
			row.CreatedAt = existing.CreatedAt
		} else {
			row.ID = uuid.New()
			row.CreatedAt = time.Now().UTC()
		}
		row.OwnerID = owner
		row.UpdatedAt = time.Now().UTC()
		if err := tx.Save(row).Error; err != nil {
			return err
		}
		return bumpMemory(tx, row.BotID)
	})
}
func bumpMemory(tx *gorm.DB, bot uuid.UUID) error {
	return tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "bot_id"}}, DoUpdates: clause.Assignments(map[string]interface{}{"revision": gorm.Expr("agent_memory_revisions.revision + 1")})}).Create(&model.AgentMemoryRevision{BotID: bot, Revision: 1}).Error
}
func (r *AgentMemoryRepository) Delete(ctx context.Context, owner, id uuid.UUID) error {
	return agentDB(ctx, r.db).Transaction(func(tx *gorm.DB) error {
		var row model.AgentMemory
		if err := tx.Where("id = ? AND owner_id = ?", id, owner).First(&row).Error; err != nil {
			return err
		}
		if err := tx.Delete(&row).Error; err != nil {
			return err
		}
		if err := tx.Where("owner_id = ? AND bot_id = ?", owner, row.BotID).Delete(&model.AgentContext{}).Error; err != nil {
			return err
		}
		return bumpMemory(tx, row.BotID)
	})
}
