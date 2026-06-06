package service

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
)

var (
	ErrTaskNotFound          = errors.New("task not found")
	ErrTaskUnavailable       = errors.New("task is not available to claim")
	ErrTaskInvalidStatus     = errors.New("invalid task status")
	ErrTaskInvalidPriority   = errors.New("invalid task priority")
	ErrTaskInvalidProgress   = errors.New("progress must be between 0 and 100")
	ErrTaskInvalidDates      = errors.New("estimated end must be after estimated start")
	ErrTaskInvalidDependency = errors.New("invalid task dependency")
	ErrTaskInvalidTitle      = errors.New("task title must be between 1 and 255 characters")
	ErrTaskHasDependents     = errors.New("task has active dependents")
	ErrTaskNotAssigned       = errors.New("task is not assigned to this bot")
)

type TaskService struct {
	taskRepo *repository.TaskRepository
	botRepo  *repository.BotRepository
}

type CreateTaskRequest struct {
	Title            string             `json:"title" binding:"required,max=255"`
	Description      *string            `json:"description"`
	Priority         model.TaskPriority `json:"priority"`
	Status           model.TaskStatus   `json:"status"`
	AssigneeBotID    *uuid.UUID         `json:"assignee_bot_id"`
	EstimatedStartAt *time.Time         `json:"estimated_start_at"`
	EstimatedEndAt   *time.Time         `json:"estimated_end_at"`
	DependencyIDs    []uuid.UUID        `json:"dependency_ids"`
	LatestStatusNote *string            `json:"latest_status_note"`
}

type UpdateTaskRequest struct {
	Title            *string             `json:"title"`
	Description      *string             `json:"description"`
	Priority         *model.TaskPriority `json:"priority"`
	Status           *model.TaskStatus   `json:"status"`
	AssigneeBotID    *uuid.UUID          `json:"assignee_bot_id"`
	EstimatedStartAt *time.Time          `json:"estimated_start_at"`
	EstimatedEndAt   *time.Time          `json:"estimated_end_at"`
	Progress         *int                `json:"progress"`
	DependencyIDs    *[]uuid.UUID        `json:"dependency_ids"`
	LatestStatusNote *string             `json:"latest_status_note"`
}

type ReassignTaskRequest struct {
	AssigneeBotID    *uuid.UUID `json:"assignee_bot_id"`
	LatestStatusNote *string    `json:"latest_status_note"`
}

type RuntimeTaskProgressRequest struct {
	Progress         int     `json:"progress"`
	LatestStatusNote *string `json:"latest_status_note"`
}

type RuntimeTaskNoteRequest struct {
	LatestStatusNote *string `json:"latest_status_note"`
}

func NewTaskService(taskRepo *repository.TaskRepository, botRepo *repository.BotRepository) *TaskService {
	return &TaskService{taskRepo: taskRepo, botRepo: botRepo}
}

func (s *TaskService) Create(ctx context.Context, ownerID uuid.UUID, req CreateTaskRequest) (*model.Task, error) {
	return s.create(ctx, ownerID, "user", ownerID, req)
}

func (s *TaskService) RuntimeCreate(ctx context.Context, bot *model.Bot, req CreateTaskRequest) (*model.Task, error) {
	return s.create(ctx, bot.OwnerID, "bot", bot.ID, req)
}

func (s *TaskService) create(ctx context.Context, ownerID uuid.UUID, actorType string, actorID uuid.UUID, req CreateTaskRequest) (*model.Task, error) {
	if err := validateTaskInput(req.Title, req.EstimatedStartAt, req.EstimatedEndAt); err != nil {
		return nil, err
	}
	if err := s.validateDependencies(ctx, ownerID, uuid.Nil, req.DependencyIDs); err != nil {
		return nil, err
	}
	if err := s.validateAssignee(ctx, ownerID, req.AssigneeBotID); err != nil {
		return nil, err
	}
	priority := req.Priority
	if priority == "" {
		priority = model.TaskPriorityNormal
	}
	if !isTaskPriority(priority) {
		return nil, ErrTaskInvalidPriority
	}
	status, err := initialTaskStatus(req.Status, req.AssigneeBotID, len(req.DependencyIDs) > 0)
	if err != nil {
		return nil, err
	}
	task := &model.Task{
		OwnerID:          ownerID,
		Title:            strings.TrimSpace(req.Title),
		Description:      req.Description,
		Priority:         priority,
		Status:           status,
		AssigneeBotID:    req.AssigneeBotID,
		EstimatedStartAt: req.EstimatedStartAt,
		EstimatedEndAt:   req.EstimatedEndAt,
		LatestStatusNote: req.LatestStatusNote,
	}
	if err := s.taskRepo.Create(ctx, task, uniqueUUIDs(req.DependencyIDs), newTaskEvent(actorType, actorID, task)); err != nil {
		return nil, err
	}
	return s.Get(ctx, ownerID, task.ID)
}

func (s *TaskService) List(ctx context.Context, ownerID uuid.UUID) ([]model.Task, error) {
	if err := s.syncBlockedStatuses(ctx, ownerID); err != nil {
		return nil, err
	}
	return s.taskRepo.ListByOwner(ctx, ownerID)
}

func (s *TaskService) Get(ctx context.Context, ownerID, taskID uuid.UUID) (*model.Task, error) {
	if err := s.syncBlockedStatuses(ctx, ownerID); err != nil {
		return nil, err
	}
	task, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, ownerID)
	if err != nil {
		return nil, ErrTaskNotFound
	}
	return task, nil
}

func (s *TaskService) Update(ctx context.Context, ownerID, taskID uuid.UUID, req UpdateTaskRequest) (*model.Task, error) {
	task, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, ownerID)
	if err != nil {
		return nil, ErrTaskNotFound
	}
	if req.Title != nil {
		task.Title = strings.TrimSpace(*req.Title)
	}
	if req.Description != nil {
		task.Description = req.Description
	}
	if req.Priority != nil {
		if !isTaskPriority(*req.Priority) {
			return nil, ErrTaskInvalidPriority
		}
		task.Priority = *req.Priority
	}
	if req.AssigneeBotID != nil {
		if err := s.validateAssignee(ctx, ownerID, req.AssigneeBotID); err != nil {
			return nil, err
		}
		task.AssigneeBotID = req.AssigneeBotID
	}
	if req.EstimatedStartAt != nil {
		task.EstimatedStartAt = req.EstimatedStartAt
	}
	if req.EstimatedEndAt != nil {
		task.EstimatedEndAt = req.EstimatedEndAt
	}
	if req.Progress != nil {
		if err := validateProgress(*req.Progress); err != nil {
			return nil, err
		}
		task.Progress = *req.Progress
	}
	if req.LatestStatusNote != nil {
		task.LatestStatusNote = req.LatestStatusNote
	}
	if req.Status != nil {
		if !isTaskStatus(*req.Status) {
			return nil, ErrTaskInvalidStatus
		}
		task.Status = *req.Status
		applyTaskTimestamps(task)
	}
	if err := validateTaskInput(task.Title, task.EstimatedStartAt, task.EstimatedEndAt); err != nil {
		return nil, err
	}
	dependencyIDs := []uuid.UUID(nil)
	replaceDependencies := req.DependencyIDs != nil
	if replaceDependencies {
		dependencyIDs = uniqueUUIDs(*req.DependencyIDs)
		if err := s.validateDependencies(ctx, ownerID, taskID, dependencyIDs); err != nil {
			return nil, err
		}
	}
	if req.Status == nil && req.AssigneeBotID != nil &&
		task.Status != model.TaskStatusCompleted &&
		task.Status != model.TaskStatusPending {
		task.Status = model.TaskStatusClaimed
	}
	if err := s.taskRepo.Update(ctx, task, dependencyIDs, replaceDependencies, newTaskEvent("user", ownerID, task)); err != nil {
		return nil, err
	}
	return s.Get(ctx, ownerID, taskID)
}

func (s *TaskService) Reassign(ctx context.Context, ownerID, taskID uuid.UUID, req ReassignTaskRequest) (*model.Task, error) {
	task, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, ownerID)
	if err != nil {
		return nil, ErrTaskNotFound
	}
	if err := s.validateAssignee(ctx, ownerID, req.AssigneeBotID); err != nil {
		return nil, err
	}
	task.AssigneeBotID = req.AssigneeBotID
	task.LatestStatusNote = req.LatestStatusNote
	task.ActualEndAt = nil
	incomplete, err := s.taskRepo.HasIncompleteDependencies(ctx, taskID)
	if err != nil {
		return nil, err
	}
	if incomplete {
		task.Status = model.TaskStatusBlocked
	} else if task.AssigneeBotID != nil {
		task.Status = model.TaskStatusClaimed
	} else {
		task.Status = model.TaskStatusAvailable
	}
	if err := s.taskRepo.Update(ctx, task, nil, false, newTaskEvent("user", ownerID, task)); err != nil {
		return nil, err
	}
	return s.Get(ctx, ownerID, taskID)
}

func (s *TaskService) Delete(ctx context.Context, ownerID, taskID uuid.UUID) error {
	if _, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, ownerID); err != nil {
		return ErrTaskNotFound
	}
	hasDependents, err := s.taskRepo.HasActiveDependents(ctx, taskID)
	if err != nil {
		return err
	}
	if hasDependents {
		return ErrTaskHasDependents
	}
	if err := s.taskRepo.Delete(ctx, taskID, ownerID); err != nil {
		return ErrTaskNotFound
	}
	return nil
}

func (s *TaskService) Claim(ctx context.Context, bot *model.Bot, taskID uuid.UUID, note *string) (*model.Task, error) {
	if err := s.syncBlockedStatuses(ctx, bot.OwnerID); err != nil {
		return nil, err
	}
	task, err := s.taskRepo.Claim(ctx, taskID, bot.OwnerID, bot.ID, note)
	if errors.Is(err, repository.ErrTaskUnavailable) {
		return nil, ErrTaskUnavailable
	}
	if err != nil {
		return nil, ErrTaskNotFound
	}
	return task, nil
}

func (s *TaskService) RuntimeProgress(ctx context.Context, bot *model.Bot, taskID uuid.UUID, req RuntimeTaskProgressRequest) (*model.Task, error) {
	if err := validateProgress(req.Progress); err != nil {
		return nil, err
	}
	return s.runtimeTransition(ctx, bot, taskID, model.TaskStatusInProgress, req.Progress, req.LatestStatusNote)
}

func (s *TaskService) RuntimeComplete(ctx context.Context, bot *model.Bot, taskID uuid.UUID, req RuntimeTaskNoteRequest) (*model.Task, error) {
	return s.runtimeTransition(ctx, bot, taskID, model.TaskStatusCompleted, 100, req.LatestStatusNote)
}

func (s *TaskService) RuntimeFail(ctx context.Context, bot *model.Bot, taskID uuid.UUID, req RuntimeTaskNoteRequest) (*model.Task, error) {
	task, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, bot.OwnerID)
	if err != nil {
		return nil, ErrTaskNotFound
	}
	return s.runtimeTransition(ctx, bot, taskID, model.TaskStatusFailed, task.Progress, req.LatestStatusNote)
}

func (s *TaskService) runtimeTransition(ctx context.Context, bot *model.Bot, taskID uuid.UUID, status model.TaskStatus, progress int, note *string) (*model.Task, error) {
	task, err := s.taskRepo.GetByIDAndOwner(ctx, taskID, bot.OwnerID)
	if err != nil {
		return nil, ErrTaskNotFound
	}
	if task.AssigneeBotID == nil || *task.AssigneeBotID != bot.ID {
		return nil, ErrTaskNotAssigned
	}
	if task.Status != model.TaskStatusClaimed && task.Status != model.TaskStatusInProgress {
		return nil, ErrTaskInvalidStatus
	}
	task.Status = status
	task.Progress = progress
	task.LatestStatusNote = note
	applyTaskTimestamps(task)
	if err := s.taskRepo.Update(ctx, task, nil, false, newTaskEvent("bot", bot.ID, task)); err != nil {
		return nil, err
	}
	return s.Get(ctx, bot.OwnerID, taskID)
}

func (s *TaskService) validateAssignee(ctx context.Context, ownerID uuid.UUID, botID *uuid.UUID) error {
	if botID == nil {
		return nil
	}
	bot, err := s.botRepo.GetByIDAndOwner(ctx, *botID, ownerID)
	if err != nil || bot.Status != model.BotStatusEnabled {
		return ErrBotNotFound
	}
	return nil
}

func (s *TaskService) validateDependencies(ctx context.Context, ownerID, taskID uuid.UUID, ids []uuid.UUID) error {
	ids = uniqueUUIDs(ids)
	for _, id := range ids {
		if id == taskID {
			return ErrTaskInvalidDependency
		}
	}
	count, err := s.taskRepo.CountOwnedTasks(ctx, ownerID, ids)
	if err != nil {
		return err
	}
	if count != int64(len(ids)) {
		return ErrTaskInvalidDependency
	}
	for _, id := range ids {
		hasPath, err := s.hasDependencyPath(ctx, id, taskID, map[uuid.UUID]bool{})
		if err != nil {
			return err
		}
		if hasPath {
			return ErrTaskInvalidDependency
		}
	}
	return nil
}

func (s *TaskService) hasDependencyPath(ctx context.Context, current, target uuid.UUID, visited map[uuid.UUID]bool) (bool, error) {
	if current == target {
		return true, nil
	}
	if visited[current] {
		return false, nil
	}
	visited[current] = true
	ids, err := s.taskRepo.ListDependencyIDs(ctx, current)
	if err != nil {
		return false, err
	}
	for _, id := range ids {
		found, err := s.hasDependencyPath(ctx, id, target, visited)
		if err != nil || found {
			return found, err
		}
	}
	return false, nil
}

func (s *TaskService) syncBlockedStatuses(ctx context.Context, ownerID uuid.UUID) error {
	tasks, err := s.taskRepo.ListStatusesByOwner(ctx, ownerID)
	if err != nil {
		return err
	}
	for i := range tasks {
		task := &tasks[i]
		if task.Status == model.TaskStatusCompleted || task.Status == model.TaskStatusFailed || task.Status == model.TaskStatusPending {
			continue
		}
		incomplete, err := s.taskRepo.HasIncompleteDependencies(ctx, task.ID)
		if err != nil {
			return err
		}
		next := task.Status
		if incomplete {
			next = model.TaskStatusBlocked
		} else if task.Status == model.TaskStatusBlocked {
			next = unlockedTaskStatus(task.AssigneeBotID, false)
		}
		if next != task.Status {
			task.Status = next
			if err := s.taskRepo.UpdateStatus(ctx, task, newTaskEvent("system", uuid.Nil, task)); err != nil {
				return err
			}
		}
	}
	return nil
}

func initialTaskStatus(requested model.TaskStatus, assigneeBotID *uuid.UUID, hasDependencies bool) (model.TaskStatus, error) {
	if requested != "" && requested != model.TaskStatusPending && requested != model.TaskStatusAvailable {
		return "", ErrTaskInvalidStatus
	}
	if requested == model.TaskStatusPending {
		return model.TaskStatusPending, nil
	}
	return unlockedTaskStatus(assigneeBotID, hasDependencies), nil
}

func unlockedTaskStatus(assigneeBotID *uuid.UUID, hasDependencies bool) model.TaskStatus {
	if hasDependencies {
		return model.TaskStatusBlocked
	}
	if assigneeBotID != nil {
		return model.TaskStatusClaimed
	}
	return model.TaskStatusAvailable
}

func applyTaskTimestamps(task *model.Task) {
	now := time.Now()
	if task.Status == model.TaskStatusInProgress && task.ActualStartAt == nil {
		task.ActualStartAt = &now
	}
	if task.Status == model.TaskStatusCompleted || task.Status == model.TaskStatusFailed {
		task.ActualEndAt = &now
	}
	if task.Status == model.TaskStatusCompleted {
		task.Progress = 100
	}
}

func validateTaskInput(title string, start, end *time.Time) error {
	title = strings.TrimSpace(title)
	if title == "" || utf8.RuneCountInString(title) > 255 {
		return ErrTaskInvalidTitle
	}
	if start != nil && end != nil && !end.After(*start) {
		return ErrTaskInvalidDates
	}
	return nil
}

func validateProgress(progress int) error {
	if progress < 0 || progress > 100 {
		return ErrTaskInvalidProgress
	}
	return nil
}

func isTaskStatus(status model.TaskStatus) bool {
	switch status {
	case model.TaskStatusPending, model.TaskStatusAvailable, model.TaskStatusClaimed, model.TaskStatusInProgress, model.TaskStatusCompleted, model.TaskStatusFailed, model.TaskStatusBlocked:
		return true
	default:
		return false
	}
}

func isTaskPriority(priority model.TaskPriority) bool {
	switch priority {
	case model.TaskPriorityLow, model.TaskPriorityNormal, model.TaskPriorityHigh, model.TaskPriorityCritical:
		return true
	default:
		return false
	}
}

func uniqueUUIDs(ids []uuid.UUID) []uuid.UUID {
	seen := make(map[uuid.UUID]struct{}, len(ids))
	result := make([]uuid.UUID, 0, len(ids))
	for _, id := range ids {
		if id == uuid.Nil {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		result = append(result, id)
	}
	return result
}

func newTaskEvent(actorType string, actorID uuid.UUID, task *model.Task) *model.TaskEvent {
	event := &model.TaskEvent{
		TaskID:    task.ID,
		ActorType: actorType,
		Status:    task.Status,
		Progress:  task.Progress,
		Note:      task.LatestStatusNote,
	}
	if actorID != uuid.Nil {
		event.ActorID = &actorID
	}
	return event
}
