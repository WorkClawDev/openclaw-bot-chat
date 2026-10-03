package repository

import (
	"context"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"strings"
	"time"
)

var ErrAgentLease = errors.New("execution lease is stale, cancelled, or held by another worker")
var ErrAgentState = errors.New("invalid execution state")

type AgentRunOutbox struct {
	MessageID string        `json:"message_id"`
	Status    string        `json:"status"`
	Response  model.JSONMap `json:"response"`
}

type AgentRunRepository struct{ db *gorm.DB }

func NewAgentRunRepository(db *gorm.DB) *AgentRunRepository { return &AgentRunRepository{db: db} }
func (r *AgentRunRepository) Create(ctx context.Context, bot *model.Bot, trigger, conversation string, taskID *uuid.UUID, input model.JSONMap) (*model.AgentRun, error) {
	var row model.AgentRun
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		attempt := 1
		if taskID != nil {
			var task model.Task
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ? AND assignee_bot_id = ?", *taskID, bot.OwnerID, bot.ID).First(&task).Error; err != nil {
				return err
			}
			if task.Status != model.TaskStatusClaimed && task.Status != model.TaskStatusInProgress {
				return ErrAgentState
			}
			var previous model.AgentRun
			err := tx.Where("task_id = ?", *taskID).Order("attempt DESC").First(&previous).Error
			if err == nil {
				if previous.Status != "succeeded" && previous.Status != "failed" && previous.Status != "cancelled" {
					row = previous
					return nil
				}
				attempt = previous.Attempt + 1
			} else if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
			trigger = fmt.Sprintf("task:%s:%d", taskID.String(), attempt)
		}
		row = model.AgentRun{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, TriggerKey: trigger, TaskID: taskID, Conversation: conversation, Attempt: attempt, Status: "queued", MaxSteps: 80, Input: input, CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
		created := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&row)
		if created.Error != nil {
			return created.Error
		}
		if created.RowsAffected == 1 {
			return appendAgentEvent(tx, &row, "queued", model.JSONMap{})
		}
		row.ID = uuid.Nil
		return tx.Where("bot_id = ? AND owner_id = ? AND trigger_key = ?", bot.ID, bot.OwnerID, trigger).First(&row).Error
	})
	return &row, err
}
func (r *AgentRunRepository) Get(ctx context.Context, owner uuid.UUID, bot *uuid.UUID, id uuid.UUID) (*model.AgentRun, error) {
	var row model.AgentRun
	query := r.db.WithContext(ctx).Where("id = ? AND owner_id = ?", id, owner)
	if bot != nil {
		query = query.Where("bot_id = ?", *bot)
	}
	err := query.First(&row).Error
	return &row, err
}
func (r *AgentRunRepository) List(ctx context.Context, owner uuid.UUID, bot *uuid.UUID) ([]model.AgentRun, error) {
	var rows []model.AgentRun
	query := r.db.WithContext(ctx).Where("owner_id = ?", owner)
	if bot != nil {
		query = query.Where("bot_id = ?", *bot)
	}
	err := query.Order("created_at DESC").Limit(200).Find(&rows).Error
	return rows, err
}
func (r *AgentRunRepository) Claim(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, now int64) (*model.AgentRun, error) {
	var row model.AgentRun
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ? AND bot_id = ?", id, bot.OwnerID, bot.ID).First(&row).Error; err != nil {
			return err
		}
		if row.CancelRequested {
			if row.LeaseUntil <= now {
				tx.Model(&model.AgentRun{}).Where("id = ?", row.ID).Updates(map[string]interface{}{"status": "cancelled", "lease_until": 0})
			}
			return ErrAgentLease
		}
		if row.Status == "waiting_approval" {
			var count int64
			if err := tx.Model(&model.AgentApproval{}).Where("run_id = ? AND status = 'pending' AND expires_at > ?", row.ID.String(), time.Unix(now/1000, 0).UTC()).Count(&count).Error; err != nil {
				return err
			}
			if count > 0 {
				return ErrAgentState
			}
			row.Status = "queued"
		}
		if row.Status != "queued" && row.Status != "running" {
			return ErrAgentState
		}
		if row.LeaseUntil > now {
			return ErrAgentLease
		}
		if row.TaskID != nil {
			var task model.Task
			if err := tx.Where("id = ?", *row.TaskID).First(&task).Error; err != nil {
				return err
			}
			if task.Status == model.TaskStatusCancelled {
				return ErrAgentLease
			}
		}
		oldFence := row.Fence
		row.Fence++
		row.WorkerID = worker
		row.Status = "running"
		row.LeaseUntil = now + 15000
		row.UpdatedAt = time.Now().UTC()
		result := tx.Model(&model.AgentRun{}).Where("id = ? AND fence = ? AND lease_until <= ?", row.ID, oldFence, now).Updates(map[string]interface{}{"fence": row.Fence, "worker_id": worker, "status": "running", "lease_until": row.LeaseUntil, "updated_at": row.UpdatedAt})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrAgentLease
		}
		if row.TaskID != nil {
			now := time.Now().UTC()
			if err := tx.Model(&model.Task{}).Where("id = ?", *row.TaskID).Updates(map[string]interface{}{"status": model.TaskStatusInProgress, "actual_start_at": now, "updated_at": now}).Error; err != nil {
				return err
			}
		}
		return appendAgentEvent(tx, &row, "running", model.JSONMap{"fence": row.Fence})
	})
	return &row, err
}
func ValidateAgentLease(row *model.AgentRun, worker string, fence, now int64) error {
	if row.Status != "running" || row.WorkerID != worker || row.Fence != fence || row.LeaseUntil <= now || row.CancelRequested {
		return ErrAgentLease
	}
	return nil
}
func (r *AgentRunRepository) Validate(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, fence int64) error {
	row, err := r.Get(ctx, bot.OwnerID, &bot.ID, id)
	if err != nil {
		return err
	}
	return ValidateAgentLease(row, worker, fence, time.Now().UnixMilli())
}
func (r *AgentRunRepository) Heartbeat(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, fence int64) (*model.AgentRun, error) {
	var row model.AgentRun
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND bot_id = ? AND owner_id = ?", id, bot.ID, bot.OwnerID).First(&row).Error; err != nil {
			return err
		}
		if row.CancelRequested && row.WorkerID == worker && row.Fence == fence && row.LeaseUntil > time.Now().UnixMilli() {
			return nil
		}
		if err := ValidateAgentLease(&row, worker, fence, time.Now().UnixMilli()); err != nil {
			return err
		}
		if row.TaskID != nil {
			var task model.Task
			if err := tx.Where("id = ?", *row.TaskID).First(&task).Error; err != nil {
				return err
			}
			if task.Status == model.TaskStatusCancelled {
				row.CancelRequested = true
				return nil
			}
		}
		row.LeaseUntil = time.Now().UnixMilli() + 15000
		return tx.Model(&model.AgentRun{}).Where("id = ? AND fence = ?", id, fence).Update("lease_until", row.LeaseUntil).Error
	})
	return &row, err
}
func (r *AgentRunRepository) Event(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, fence int64, kind string, data model.JSONMap) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND bot_id = ? AND owner_id = ?", id, bot.ID, bot.OwnerID).First(&row).Error; err != nil {
			return err
		}
		if err := ValidateAgentLease(&row, worker, fence, time.Now().UnixMilli()); err != nil {
			return err
		}
		if row.Steps >= row.MaxSteps {
			return errors.New("execution budget exhausted")
		}
		if kind == "tool_intent" || kind == "model_request" {
			row.Steps++
			if err := tx.Model(&model.AgentRun{}).Where("id = ?", id).Update("steps", row.Steps).Error; err != nil {
				return err
			}
		}
		return appendAgentEvent(tx, &row, kind, data)
	})
}
func (r *AgentRunRepository) Transition(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, fence int64, status string, result model.JSONMap, note string, receipts ...*AgentRunOutbox) error {
	allowed := map[string]bool{"waiting_input": true, "waiting_approval": true, "paused": true, "succeeded": true, "failed": true, "cancelled": true, "queued": true}
	if !allowed[status] {
		return ErrAgentState
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND bot_id = ? AND owner_id = ?", id, bot.ID, bot.OwnerID).First(&row).Error; err != nil {
			return err
		}
		if row.WorkerID != worker || row.Fence != fence || row.LeaseUntil <= time.Now().UnixMilli() || row.Status != "running" {
			return ErrAgentLease
		}
		if row.CancelRequested && status != "cancelled" {
			return ErrAgentLease
		}
		row.Status = status
		row.Result = result
		errorNote := ""
		if status == "failed" {
			errorNote = note
		}
		row.Error = errorNote
		row.LeaseUntil = 0
		if err := tx.Model(&model.AgentRun{}).Where("id = ? AND fence = ?", id, fence).Updates(map[string]interface{}{"status": status, "result": result, "error": errorNote, "lease_until": 0, "updated_at": time.Now().UTC()}).Error; err != nil {
			return err
		}
		if row.TaskID != nil && (status == "succeeded" || status == "failed" || status == "cancelled") {
			var task model.Task
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ? AND assignee_bot_id = ?", *row.TaskID, bot.OwnerID, bot.ID).First(&task).Error; err != nil {
				return err
			}
			if task.Status == model.TaskStatusCancelled && status != "cancelled" {
				return ErrAgentLease
			}
			taskStatus := model.TaskStatusFailed
			progress := task.Progress
			if status == "succeeded" {
				taskStatus = model.TaskStatusAwaitingReview
				progress = 100
			} else if status == "cancelled" {
				taskStatus = model.TaskStatusCancelled
			}
			now := time.Now().UTC()
			if err := tx.Model(&model.Task{}).Where("id = ?", task.ID).Updates(map[string]interface{}{"status": taskStatus, "progress": progress, "result": result, "latest_status_note": note, "actual_end_at": now, "updated_at": now}).Error; err != nil {
				return err
			}
			if err := tx.Create(&model.TaskEvent{ID: uuid.New(), TaskID: task.ID, ActorType: "bot", ActorID: &bot.ID, EventType: "agent." + status, Status: taskStatus, Progress: progress, Note: &note, Payload: model.JSONMap{"run_id": row.ID}, CreatedAt: now}).Error; err != nil {
				return err
			}
		}
		if len(receipts) > 0 && receipts[0] != nil {
			receipt := receipts[0]
			update := tx.Model(&model.AgentInbox{}).Where("bot_id = ? AND owner_id = ? AND message_id = ?", bot.ID, bot.OwnerID, receipt.MessageID).Updates(map[string]interface{}{"status": receipt.Status, "response": receipt.Response, "delivered": false, "updated_at": time.Now().UTC()})
			if update.Error != nil {
				return update.Error
			}
			if update.RowsAffected != 1 {
				return gorm.ErrRecordNotFound
			}
		}
		return appendAgentEvent(tx, &row, status, model.JSONMap{"note": note, "result": result})
	})
}
func appendAgentEvent(tx *gorm.DB, row *model.AgentRun, kind string, data model.JSONMap) error {
	row.EventSeq++
	if err := tx.Model(&model.AgentRun{}).Where("id = ?", row.ID).Update("event_seq", row.EventSeq).Error; err != nil {
		return err
	}
	return tx.Create(&model.AgentRunEvent{ID: uuid.New(), RunID: row.ID, Seq: row.EventSeq, Type: kind, Data: data, CreatedAt: time.Now().UTC()}).Error
}
func (r *AgentRunRepository) Events(ctx context.Context, owner uuid.UUID, id uuid.UUID, after int64) ([]model.AgentRunEvent, error) {
	if _, err := r.Get(ctx, owner, nil, id); err != nil {
		return nil, err
	}
	var rows []model.AgentRunEvent
	err := r.db.WithContext(ctx).Where("run_id = ? AND seq > ?", id, after).Order("seq ASC").Limit(200).Find(&rows).Error
	return rows, err
}
func (r *AgentRunRepository) UserAction(ctx context.Context, owner, id uuid.UUID, action, input string) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ?", id, owner).First(&row).Error; err != nil {
			return err
		}
		changes := map[string]interface{}{"updated_at": time.Now().UTC()}
		if action == "cancel" {
			changes["cancel_requested"] = true
			if row.TaskID != nil {
				if err := tx.Model(&model.Task{}).Where("id = ? AND owner_id = ?", *row.TaskID, owner).Update("status", model.TaskStatusCancelled).Error; err != nil {
					return err
				}
			}
			if row.Status != "running" {
				changes["status"] = "cancelled"
			}
		}
		if action == "resume" {
			if row.Status != "waiting_input" && row.Status != "paused" && row.Status != "failed" {
				return ErrAgentState
			}
			if row.Status == "waiting_input" && input == "" {
				return ErrAgentState
			}
			if row.Input == nil {
				row.Input = model.JSONMap{}
			}
			row.Input["supplement"] = input
			changes["input"] = row.Input
			if strings.HasPrefix(row.TriggerKey, "chat:") {
				if err := tx.Model(&model.AgentInbox{}).Where("bot_id = ? AND message_id = ?", row.BotID, strings.TrimPrefix(row.TriggerKey, "chat:")).Update("status", "accepted").Error; err != nil {
					return err
				}
			}
			if row.TaskID != nil {
				if err := tx.Model(&model.Task{}).Where("id = ? AND owner_id = ? AND assignee_bot_id = ?", *row.TaskID, owner, row.BotID).Updates(map[string]interface{}{"status": model.TaskStatusClaimed, "actual_end_at": nil, "error": nil}).Error; err != nil {
					return err
				}
			}
			changes["status"] = "queued"
			changes["cancel_requested"] = false
			changes["fence"] = row.Fence + 1
			changes["lease_until"] = 0
			if row.Status == "paused" {
				changes["max_steps"] = row.MaxSteps + 80
			}
		}
		if action != "cancel" && action != "resume" {
			return ErrAgentState
		}
		if err := tx.Model(&model.AgentRun{}).Where("id = ?", id).Updates(changes).Error; err != nil {
			return err
		}
		return appendAgentEvent(tx, &row, action, model.JSONMap{"input": input})
	})
}
func (r *AgentRunRepository) Fenced(ctx context.Context, bot *model.Bot, id uuid.UUID, worker string, fence int64, allowCancelled bool, execute func(context.Context) error) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentRun
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ? AND bot_id = ?", id, bot.OwnerID, bot.ID).First(&row).Error; err != nil {
			return err
		}
		if allowCancelled {
			row.CancelRequested = false
		}
		if err := ValidateAgentLease(&row, worker, fence, time.Now().UnixMilli()); err != nil {
			return err
		}
		return execute(WithAgentTransaction(ctx, tx))
	})
}
func (r *AgentRunRepository) HasTaskRun(ctx context.Context, owner, task uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.AgentRun{}).Where("owner_id = ? AND task_id = ?", owner, task).Count(&count).Error
	return count > 0, err
}
