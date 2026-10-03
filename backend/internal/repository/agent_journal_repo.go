package repository

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"time"
)

type AgentJournalRepository struct{ db *gorm.DB }

func NewAgentJournalRepository(db *gorm.DB) *AgentJournalRepository {
	return &AgentJournalRepository{db: db}
}
func (r *AgentJournalRepository) Accept(ctx context.Context, bot *model.Bot, id string, msg model.JSONMap) (*model.AgentInbox, error) {
	row := model.AgentInbox{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, MessageID: id, Message: msg, Status: "accepted", CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
	if err := agentDB(ctx, r.db).Clauses(clause.OnConflict{DoNothing: true}).Create(&row).Error; err != nil {
		return nil, err
	}
	row.ID = uuid.Nil
	err := agentDB(ctx, r.db).Where("bot_id = ? AND owner_id = ? AND message_id = ?", bot.ID, bot.OwnerID, id).First(&row).Error
	return &row, err
}
func (r *AgentJournalRepository) Pending(ctx context.Context, bot *model.Bot) ([]model.AgentInbox, error) {
	var rows []model.AgentInbox
	err := agentDB(ctx, r.db).Where("bot_id = ? AND owner_id = ? AND (status IN ('accepted','waiting_approval') OR delivered = false)", bot.ID, bot.OwnerID).Order("CASE WHEN status = 'accepted' THEN 0 ELSE 1 END, created_at ASC").Limit(200).Find(&rows).Error
	return rows, err
}
func (r *AgentJournalRepository) Finish(ctx context.Context, bot *model.Bot, id, status string, response model.JSONMap) error {
	if status != "accepted" && status != "completed" && status != "waiting_approval" && status != "waiting_input" && status != "cancelled" {
		return errors.New("invalid inbox status")
	}
	result := agentDB(ctx, r.db).Model(&model.AgentInbox{}).Where("bot_id = ? AND owner_id = ? AND message_id = ?", bot.ID, bot.OwnerID, id).Updates(map[string]interface{}{"status": status, "response": response, "updated_at": time.Now().UTC()})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
func (r *AgentJournalRepository) Delivered(ctx context.Context, bot *model.Bot, id string) error {
	return agentDB(ctx, r.db).Model(&model.AgentInbox{}).Where("bot_id = ? AND owner_id = ? AND message_id = ?", bot.ID, bot.OwnerID, id).Update("delivered", true).Error
}
func (r *AgentJournalRepository) Context(ctx context.Context, bot *model.Bot, scope string) (model.JSONMap, error) {
	var row model.AgentContext
	err := agentDB(ctx, r.db).Where("bot_id = ? AND owner_id = ? AND scope = ?", bot.ID, bot.OwnerID, scope).First(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return model.JSONMap{}, nil
	}
	return row.Data, err
}
func (r *AgentJournalRepository) SaveContext(ctx context.Context, bot *model.Bot, scope string, data model.JSONMap) error {
	return agentDB(ctx, r.db).Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "bot_id"}, {Name: "scope"}}, DoUpdates: clause.Assignments(map[string]interface{}{"data": data, "updated_at": time.Now().UTC()})}).Create(&model.AgentContext{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, Scope: scope, Data: data, UpdatedAt: time.Now().UTC()}).Error
}
func (r *AgentJournalRepository) PrepareTool(ctx context.Context, bot *model.Bot, runID, key, tool string, idempotent bool) (*model.AgentToolCall, error) {
	row := model.AgentToolCall{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, RunID: runID, Key: key, Tool: tool, Idempotent: idempotent, Status: "started", CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
	created := agentDB(ctx, r.db).Clauses(clause.OnConflict{DoNothing: true}).Create(&row)
	if created.Error != nil {
		return nil, created.Error
	}
	if created.RowsAffected == 1 {
		return &row, nil
	}
	row.ID = uuid.Nil
	if err := agentDB(ctx, r.db).Where("bot_id = ? AND owner_id = ? AND run_id = ? AND key = ?", bot.ID, bot.OwnerID, runID, key).First(&row).Error; err != nil {
		return nil, err
	}
	if row.Status == "started" && !row.Idempotent {
		row.Status = "uncertain"
	}
	return &row, nil
}
func (r *AgentJournalRepository) CompleteTool(ctx context.Context, bot *model.Bot, runID, key string, result model.JSONMap) error {
	return agentDB(ctx, r.db).Model(&model.AgentToolCall{}).Where("bot_id = ? AND owner_id = ? AND run_id = ? AND key = ?", bot.ID, bot.OwnerID, runID, key).Updates(map[string]interface{}{"status": "completed", "result": result, "updated_at": time.Now().UTC()}).Error
}

func (r *AgentJournalRepository) UncertainTools(ctx context.Context, owner uuid.UUID) ([]model.AgentToolCall, error) {
	var rows []model.AgentToolCall
	err := r.db.WithContext(ctx).Table("agent_tool_calls t").Select("t.*").Joins("JOIN agent_runs r ON CAST(r.id AS TEXT) = t.run_id").Where("t.owner_id = ? AND t.idempotent = ? AND t.status = 'started' AND r.lease_until = 0 AND r.status IN ?", owner, false, []string{"waiting_input", "paused", "failed"}).Limit(100).Scan(&rows).Error
	return rows, err
}
func (r *AgentJournalRepository) Reconcile(ctx context.Context, owner, id uuid.UUID, outcome, evidence string) error {
	if (outcome != "completed" && outcome != "not_applied") || len(evidence) < 3 || len(evidence) > 8000 {
		return errors.New("reconciliation evidence required")
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var call model.AgentToolCall
		if err := tx.Where("id = ? AND owner_id = ?", id, owner).First(&call).Error; err != nil {
			return err
		}
		var run model.AgentRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ?", call.RunID, owner).First(&run).Error; err != nil {
			return err
		}
		if run.LeaseUntil != 0 || call.Status != "started" || call.Idempotent || (run.Status != "waiting_input" && run.Status != "paused" && run.Status != "failed") {
			return ErrAgentState
		}
		if outcome == "completed" {
			if err := tx.Model(&call).Updates(map[string]interface{}{"status": "completed", "result": model.JSONMap{"value": evidence, "reconciled_by": owner.String()}, "updated_at": time.Now().UTC()}).Error; err != nil {
				return err
			}
		} else {
			if err := tx.Delete(&call).Error; err != nil {
				return err
			}
		}
		return appendAgentEvent(tx, &run, "tool_reconciled", model.JSONMap{"tool": call.Tool, "outcome": outcome, "evidence": evidence, "actor_id": owner.String()})
	})
}
