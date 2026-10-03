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
