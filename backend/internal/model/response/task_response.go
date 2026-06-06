package response

import (
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

type TaskResponse struct {
	ID               uuid.UUID                `json:"id"`
	OwnerID          uuid.UUID                `json:"owner_id"`
	Title            string                   `json:"title"`
	Description      *string                  `json:"description,omitempty"`
	Priority         model.TaskPriority       `json:"priority"`
	Status           model.TaskStatus         `json:"status"`
	AssigneeBotID    *uuid.UUID               `json:"assignee_bot_id,omitempty"`
	AssigneeBot      *BotResponse             `json:"assignee_bot,omitempty"`
	EstimatedStartAt *time.Time               `json:"estimated_start_at,omitempty"`
	EstimatedEndAt   *time.Time               `json:"estimated_end_at,omitempty"`
	ActualStartAt    *time.Time               `json:"actual_start_at,omitempty"`
	ActualEndAt      *time.Time               `json:"actual_end_at,omitempty"`
	Progress         int                      `json:"progress"`
	LatestStatusNote *string                  `json:"latest_status_note,omitempty"`
	Dependencies     []TaskDependencyResponse `json:"dependencies"`
	Events           []TaskEventResponse      `json:"events"`
	CreatedAt        time.Time                `json:"created_at"`
	UpdatedAt        time.Time                `json:"updated_at"`
}

type TaskDependencyResponse struct {
	ID              uuid.UUID  `json:"id"`
	DependsOnTaskID uuid.UUID  `json:"depends_on_task_id"`
	DependsOnTask   *TaskBrief `json:"depends_on_task,omitempty"`
}

type TaskBrief struct {
	ID       uuid.UUID        `json:"id"`
	Title    string           `json:"title"`
	Status   model.TaskStatus `json:"status"`
	Progress int              `json:"progress"`
}

type TaskEventResponse struct {
	ID        uuid.UUID        `json:"id"`
	ActorType string           `json:"actor_type"`
	ActorID   *uuid.UUID       `json:"actor_id,omitempty"`
	Status    model.TaskStatus `json:"status"`
	Progress  int              `json:"progress"`
	Note      *string          `json:"note,omitempty"`
	CreatedAt time.Time        `json:"created_at"`
}

func NewTaskResponse(task *model.Task) *TaskResponse {
	if task == nil {
		return nil
	}
	dependencies := make([]TaskDependencyResponse, 0, len(task.Dependencies))
	for _, dependency := range task.Dependencies {
		var brief *TaskBrief
		if dependency.DependsOnTask != nil {
			brief = &TaskBrief{
				ID:       dependency.DependsOnTask.ID,
				Title:    dependency.DependsOnTask.Title,
				Status:   dependency.DependsOnTask.Status,
				Progress: dependency.DependsOnTask.Progress,
			}
		}
		dependencies = append(dependencies, TaskDependencyResponse{
			ID:              dependency.ID,
			DependsOnTaskID: dependency.DependsOnTaskID,
			DependsOnTask:   brief,
		})
	}
	events := make([]TaskEventResponse, 0, len(task.Events))
	for _, event := range task.Events {
		events = append(events, TaskEventResponse{
			ID:        event.ID,
			ActorType: event.ActorType,
			ActorID:   event.ActorID,
			Status:    event.Status,
			Progress:  event.Progress,
			Note:      event.Note,
			CreatedAt: event.CreatedAt,
		})
	}
	return &TaskResponse{
		ID:               task.ID,
		OwnerID:          task.OwnerID,
		Title:            task.Title,
		Description:      task.Description,
		Priority:         task.Priority,
		Status:           task.Status,
		AssigneeBotID:    task.AssigneeBotID,
		AssigneeBot:      NewBotResponse(task.AssigneeBot),
		EstimatedStartAt: task.EstimatedStartAt,
		EstimatedEndAt:   task.EstimatedEndAt,
		ActualStartAt:    task.ActualStartAt,
		ActualEndAt:      task.ActualEndAt,
		Progress:         task.Progress,
		LatestStatusNote: task.LatestStatusNote,
		Dependencies:     dependencies,
		Events:           events,
		CreatedAt:        task.CreatedAt,
		UpdatedAt:        task.UpdatedAt,
	}
}

func NewTaskResponses(tasks []model.Task) []TaskResponse {
	responses := make([]TaskResponse, 0, len(tasks))
	for i := range tasks {
		responses = append(responses, *NewTaskResponse(&tasks[i]))
	}
	return responses
}
