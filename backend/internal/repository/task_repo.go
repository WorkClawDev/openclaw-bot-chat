package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type TaskRepository struct {
	db *gorm.DB
}

func NewTaskRepository(db *gorm.DB) *TaskRepository {
	return &TaskRepository{db: db}
}

func (r *TaskRepository) Create(ctx context.Context, task *model.Task, dependencyIDs []uuid.UUID, event *model.TaskEvent) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(task).Error; err != nil {
			return err
		}
		if err := replaceTaskDependencies(tx, task.ID, dependencyIDs); err != nil {
			return err
		}
		if event != nil {
			event.TaskID = task.ID
			return tx.Create(event).Error
		}
		return nil
	})
}

func (r *TaskRepository) GetByIDAndOwner(ctx context.Context, id, ownerID uuid.UUID) (*model.Task, error) {
	var task model.Task
	err := r.taskQuery(ctx).
		Where("tasks.id = ? AND tasks.owner_id = ?", id, ownerID).
		First(&task).Error
	if err != nil {
		return nil, err
	}
	return &task, nil
}

func (r *TaskRepository) ListByOwner(ctx context.Context, ownerID uuid.UUID) ([]model.Task, error) {
	var tasks []model.Task
	err := r.taskQuery(ctx).
		Where("tasks.owner_id = ?", ownerID).
		Order("tasks.created_at DESC").
		Find(&tasks).Error
	return tasks, err
}

func (r *TaskRepository) ListStatusesByOwner(ctx context.Context, ownerID uuid.UUID) ([]model.Task, error) {
	var tasks []model.Task
	err := r.db.WithContext(ctx).
		Select("id", "status", "assignee_bot_id", "progress").
		Where("owner_id = ?", ownerID).
		Find(&tasks).Error
	return tasks, err
}

func (r *TaskRepository) ListDependencyIDs(ctx context.Context, taskID uuid.UUID) ([]uuid.UUID, error) {
	var ids []uuid.UUID
	err := r.db.WithContext(ctx).
		Model(&model.TaskDependency{}).
		Where("task_id = ?", taskID).
		Pluck("depends_on_task_id", &ids).Error
	return ids, err
}

func (r *TaskRepository) CountOwnedTasks(ctx context.Context, ownerID uuid.UUID, ids []uuid.UUID) (int64, error) {
	if len(ids) == 0 {
		return 0, nil
	}
	var count int64
	err := r.db.WithContext(ctx).Model(&model.Task{}).
		Where("owner_id = ? AND id IN ?", ownerID, ids).
		Count(&count).Error
	return count, err
}

func (r *TaskRepository) HasIncompleteDependencies(ctx context.Context, taskID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).
		Table("task_dependencies").
		Joins("JOIN tasks ON tasks.id = task_dependencies.depends_on_task_id").
		Where("task_dependencies.task_id = ? AND tasks.status <> ?", taskID, model.TaskStatusCompleted).
		Count(&count).Error
	return count > 0, err
}

func (r *TaskRepository) HasActiveDependents(ctx context.Context, taskID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).
		Table("task_dependencies").
		Joins("JOIN tasks ON tasks.id = task_dependencies.task_id").
		Where("task_dependencies.depends_on_task_id = ? AND tasks.deleted_at IS NULL", taskID).
		Count(&count).Error
	return count > 0, err
}

func (r *TaskRepository) Update(ctx context.Context, task *model.Task, dependencyIDs []uuid.UUID, replaceDependencies bool, event *model.TaskEvent) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(task).Error; err != nil {
			return err
		}
		if replaceDependencies {
			if err := replaceTaskDependencies(tx, task.ID, dependencyIDs); err != nil {
				return err
			}
		}
		if event != nil {
			event.TaskID = task.ID
			return tx.Create(event).Error
		}
		return nil
	})
}

func (r *TaskRepository) UpdateStatus(ctx context.Context, task *model.Task, event *model.TaskEvent) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&model.Task{}).
			Where("id = ?", task.ID).
			Update("status", task.Status).Error; err != nil {
			return err
		}
		if event != nil {
			event.TaskID = task.ID
			return tx.Create(event).Error
		}
		return nil
	})
}

func (r *TaskRepository) Claim(ctx context.Context, taskID, ownerID, botID uuid.UUID, note *string) (*model.Task, error) {
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var task model.Task
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND owner_id = ?", taskID, ownerID).
			First(&task).Error; err != nil {
			return err
		}
		if task.Status != model.TaskStatusAvailable || task.AssigneeBotID != nil {
			return ErrTaskUnavailable
		}
		var incomplete int64
		if err := tx.Table("task_dependencies").
			Joins("JOIN tasks ON tasks.id = task_dependencies.depends_on_task_id").
			Where("task_dependencies.task_id = ? AND tasks.status <> ?", taskID, model.TaskStatusCompleted).
			Count(&incomplete).Error; err != nil {
			return err
		}
		if incomplete > 0 {
			return ErrTaskUnavailable
		}
		task.Status = model.TaskStatusClaimed
		task.AssigneeBotID = &botID
		task.LatestStatusNote = note
		if err := tx.Save(&task).Error; err != nil {
			return err
		}
		return tx.Create(&model.TaskEvent{
			TaskID:    task.ID,
			ActorType: "bot",
			ActorID:   &botID,
			Status:    task.Status,
			Progress:  task.Progress,
			Note:      note,
		}).Error
	})
	if err != nil {
		return nil, err
	}
	return r.GetByIDAndOwner(ctx, taskID, ownerID)
}

func (r *TaskRepository) Delete(ctx context.Context, taskID, ownerID uuid.UUID) error {
	result := r.db.WithContext(ctx).
		Where("id = ? AND owner_id = ?", taskID, ownerID).
		Delete(&model.Task{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

func (r *TaskRepository) taskQuery(ctx context.Context) *gorm.DB {
	return r.db.WithContext(ctx).
		Preload("AssigneeBot").
		Preload("Dependencies.DependsOnTask").
		Preload("Events", func(db *gorm.DB) *gorm.DB {
			return db.Order("created_at DESC")
		})
}

func replaceTaskDependencies(tx *gorm.DB, taskID uuid.UUID, dependencyIDs []uuid.UUID) error {
	if err := tx.Where("task_id = ?", taskID).Delete(&model.TaskDependency{}).Error; err != nil {
		return err
	}
	for _, dependencyID := range dependencyIDs {
		if err := tx.Create(&model.TaskDependency{
			TaskID:          taskID,
			DependsOnTaskID: dependencyID,
		}).Error; err != nil {
			return err
		}
	}
	return nil
}
