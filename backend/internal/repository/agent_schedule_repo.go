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

type AgentScheduleRepository struct{ db *gorm.DB }

func NewAgentScheduleRepository(db *gorm.DB) *AgentScheduleRepository {
	return &AgentScheduleRepository{db}
}
func (r *AgentScheduleRepository) List(ctx context.Context, owner uuid.UUID) ([]model.AgentSchedule, error) {
	rows := []model.AgentSchedule{}
	err := r.db.WithContext(ctx).Where("owner_id = ?", owner).Order("created_at DESC").Limit(200).Find(&rows).Error
	if err != nil {
		return rows, err
	}
	for i := range rows {
		if rows[i].LastTaskID != nil {
			var task model.Task
			if err = r.db.WithContext(ctx).Select("status", "latest_status_note").Where("id = ? AND owner_id = ?", *rows[i].LastTaskID, owner).First(&task).Error; err != nil {
				return rows, err
			}
			rows[i].LastTaskStatus = string(task.Status)
			rows[i].LastTaskNote = task.LatestStatusNote
		}
	}
	return rows, nil
}
func (r *AgentScheduleRepository) Save(ctx context.Context, owner uuid.UUID, row *model.AgentSchedule) error {
	if _, err := time.LoadLocation(row.Timezone); err != nil {
		return err
	}
	if strings.TrimSpace(row.Title) == "" || len(row.Title) > 255 || strings.TrimSpace(row.Prompt) == "" || len(row.Prompt) > 16000 || row.NextAt.IsZero() || !contains([]string{"once", "daily", "weekly"}, row.Recurrence) || !contains([]string{"once", "skip"}, row.MissedPolicy) {
		return errors.New("invalid schedule")
	}
	var bot model.Bot
	if err := r.db.WithContext(ctx).Where("id = ? AND owner_id = ?", row.BotID, owner).First(&bot).Error; err != nil {
		return err
	}
	row.ID = uuid.New()
	row.OwnerID = owner
	row.Status = "active"
	row.CreatedAt = time.Now().UTC()
	row.UpdatedAt = row.CreatedAt
	return r.db.WithContext(ctx).Create(row).Error
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func (r *AgentScheduleRepository) Action(ctx context.Context, owner, id uuid.UUID, action string) error {
	status := map[string]string{"pause": "paused", "resume": "active", "cancel": "cancelled"}[action]
	if status == "" {
		return errors.New("invalid action")
	}
	result := r.db.WithContext(ctx).Model(&model.AgentSchedule{}).Where("owner_id = ? AND id = ? AND status != 'cancelled' AND status != 'completed'", owner, id).Updates(map[string]interface{}{"status": status, "updated_at": time.Now().UTC()})
	if result.RowsAffected != 1 {
		return gorm.ErrRecordNotFound
	}
	return result.Error
}
func nextScheduleTime(at time.Time, recurrence, timezone string) (time.Time, error) {
	loc, err := time.LoadLocation(timezone)
	if err != nil {
		return time.Time{}, err
	}
	days := 1
	if recurrence == "weekly" {
		days = 7
	}
	if recurrence == "once" {
		return time.Time{}, nil
	}
	return at.In(loc).AddDate(0, 0, days).UTC(), nil
}
func (r *AgentScheduleRepository) Tick(ctx context.Context, now time.Time) error {
	var ids []uuid.UUID
	if err := r.db.WithContext(ctx).Model(&model.AgentSchedule{}).Where("status = 'active' AND next_at <= ?", now).Limit(100).Pluck("id", &ids).Error; err != nil {
		return err
	}
	var failures []error
	for _, id := range ids {
		if err := r.tickOne(ctx, id, now); err != nil {
			failures = append(failures, fmt.Errorf("schedule %s: %w", id, err))
		}
	}
	return errors.Join(failures...)
}
func (r *AgentScheduleRepository) tickOne(ctx context.Context, id uuid.UUID, now time.Time) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var row model.AgentSchedule
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ?", id).First(&row).Error; err != nil {
			return err
		}
		if row.Status != "active" || row.NextAt.After(now) {
			return nil
		}
		at := row.NextAt
		next, err := nextScheduleTime(at, row.Recurrence, row.Timezone)
		if err != nil {
			return err
		}
		for i := 0; !next.IsZero() && !next.After(now); i++ {
			if i > 36600 {
				return errors.New("schedule backlog exceeds limit")
			}
			at = next
			next, err = nextScheduleTime(next, row.Recurrence, row.Timezone)
			if err != nil {
				return err
			}
		}
		occurrence := model.AgentScheduleOccurrence{ID: uuid.New(), ScheduleID: row.ID, At: at, Status: "created", CreatedAt: now}
		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&occurrence)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 1 {
			if row.MissedPolicy == "skip" && now.Sub(at) > time.Minute {
				occurrence.Status = "skipped"
			} else {
				taskID := uuid.New()
				prompt := row.Prompt
				task := model.Task{ID: taskID, OwnerID: row.OwnerID, Title: row.Title, Description: &prompt, Priority: model.TaskPriorityNormal, Status: model.TaskStatusClaimed, AssigneeBotID: &row.BotID, DispatchedAt: &now, ClaimedAt: &now, CreatedAt: now, UpdatedAt: now}
				if err = tx.Omit(clause.Associations).Create(&task).Error; err != nil {
					return err
				}
				occurrence.TaskID = &taskID
				row.LastTaskID = &taskID
				event := model.TaskEvent{ID: uuid.New(), TaskID: taskID, ActorType: "system", EventType: "schedule_triggered", Status: model.TaskStatusClaimed, Payload: model.JSONMap{"schedule_id": row.ID.String(), "occurrence": at.Format(time.RFC3339)}, CreatedAt: now}
				if err = tx.Omit(clause.Associations).Create(&event).Error; err != nil {
					return err
				}
			}
			if err = tx.Save(&occurrence).Error; err != nil {
				return err
			}
		}
		row.NextAt = next
		row.UpdatedAt = now
		if next.IsZero() {
			row.Status = "completed"
		}
		return tx.Save(&row).Error
	})
}
