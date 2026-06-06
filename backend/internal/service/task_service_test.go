package service

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

func TestInitialTaskStatus(t *testing.T) {
	botID := uuid.New()
	tests := []struct {
		name         string
		requested    model.TaskStatus
		assignee     *uuid.UUID
		dependencies bool
		want         model.TaskStatus
	}{
		{name: "shared pool", want: model.TaskStatusAvailable},
		{name: "assigned", assignee: &botID, want: model.TaskStatusClaimed},
		{name: "blocked", dependencies: true, want: model.TaskStatusBlocked},
		{name: "pending", requested: model.TaskStatusPending, want: model.TaskStatusPending},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := initialTaskStatus(tt.requested, tt.assignee, tt.dependencies)
			if err != nil {
				t.Fatalf("initialTaskStatus() error = %v", err)
			}
			if got != tt.want {
				t.Fatalf("initialTaskStatus() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestInitialTaskStatusRejectsExecutionStatus(t *testing.T) {
	if _, err := initialTaskStatus(model.TaskStatusCompleted, nil, false); !errors.Is(err, ErrTaskInvalidStatus) {
		t.Fatalf("initialTaskStatus() error = %v, want ErrTaskInvalidStatus", err)
	}
}

func TestValidateTaskInputRejectsInvalidDateRange(t *testing.T) {
	start := time.Now()
	end := start.Add(-time.Minute)
	if err := validateTaskInput("task", &start, &end); !errors.Is(err, ErrTaskInvalidDates) {
		t.Fatalf("validateTaskInput() error = %v, want ErrTaskInvalidDates", err)
	}
}

func TestValidateTaskInputRejectsInvalidTitle(t *testing.T) {
	for _, title := range []string{"  ", strings.Repeat("a", 256)} {
		if err := validateTaskInput(title, nil, nil); !errors.Is(err, ErrTaskInvalidTitle) {
			t.Fatalf("validateTaskInput(%q) error = %v, want ErrTaskInvalidTitle", title, err)
		}
	}
}

func TestValidateProgress(t *testing.T) {
	for _, progress := range []int{0, 50, 100} {
		if err := validateProgress(progress); err != nil {
			t.Fatalf("validateProgress(%d) error = %v", progress, err)
		}
	}
	for _, progress := range []int{-1, 101} {
		if err := validateProgress(progress); !errors.Is(err, ErrTaskInvalidProgress) {
			t.Fatalf("validateProgress(%d) error = %v, want ErrTaskInvalidProgress", progress, err)
		}
	}
}

func TestIsTaskPriority(t *testing.T) {
	for _, priority := range []model.TaskPriority{
		model.TaskPriorityLow,
		model.TaskPriorityNormal,
		model.TaskPriorityHigh,
		model.TaskPriorityCritical,
	} {
		if !isTaskPriority(priority) {
			t.Fatalf("isTaskPriority(%q) = false, want true", priority)
		}
	}
	if isTaskPriority("urgent") {
		t.Fatal("isTaskPriority(\"urgent\") = true, want false")
	}
}

func TestApplyTaskTimestampsCompletesTask(t *testing.T) {
	task := &model.Task{Status: model.TaskStatusCompleted, Progress: 25}
	applyTaskTimestamps(task)
	if task.Progress != 100 {
		t.Fatalf("applyTaskTimestamps() progress = %d, want 100", task.Progress)
	}
	if task.ActualEndAt == nil {
		t.Fatal("applyTaskTimestamps() did not set ActualEndAt")
	}
}

func TestNewTaskEventRecordsBotActor(t *testing.T) {
	botID := uuid.New()
	task := &model.Task{
		ID:       uuid.New(),
		Status:   model.TaskStatusAvailable,
		Progress: 0,
	}
	event := newTaskEvent("bot", botID, task)
	if event.ActorType != "bot" {
		t.Fatalf("newTaskEvent() actor type = %q, want bot", event.ActorType)
	}
	if event.ActorID == nil || *event.ActorID != botID {
		t.Fatalf("newTaskEvent() actor id = %v, want %s", event.ActorID, botID)
	}
	if event.TaskID != task.ID {
		t.Fatalf("newTaskEvent() task id = %s, want %s", event.TaskID, task.ID)
	}
}
