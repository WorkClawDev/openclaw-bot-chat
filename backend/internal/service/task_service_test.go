package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
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
	event := newTaskEvent("bot", botID, "task.claimed", task, model.JSONMap{"source": "test"})
	if event.ActorType != "bot" {
		t.Fatalf("newTaskEvent() actor type = %q, want bot", event.ActorType)
	}
	if event.EventType != "task.claimed" {
		t.Fatalf("newTaskEvent() event type = %q, want task.claimed", event.EventType)
	}
	if event.Payload["source"] != "test" {
		t.Fatalf("newTaskEvent() payload = %#v, want source=test", event.Payload)
	}
	if event.ActorID == nil || *event.ActorID != botID {
		t.Fatalf("newTaskEvent() actor id = %v, want %s", event.ActorID, botID)
	}
	if event.TaskID != task.ID {
		t.Fatalf("newTaskEvent() task id = %s, want %s", event.TaskID, task.ID)
	}
}

func TestTaskDispatchQueueResultAcceptFlow(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	ctx := context.Background()

	task, err := env.service.Create(ctx, env.owner.ID, CreateTaskRequest{
		Title:         "reviewable task",
		Status:        model.TaskStatusPending,
		AssigneeBotID: &env.bot.ID,
	})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	dispatched, err := env.service.Dispatch(ctx, env.owner.ID, task.ID, UserTaskActionRequest{})
	if err != nil {
		t.Fatalf("Dispatch() error = %v", err)
	}
	if dispatched.Status != model.TaskStatusClaimed {
		t.Fatalf("Dispatch() status = %q, want claimed", dispatched.Status)
	}
	if dispatched.DispatchedAt == nil {
		t.Fatal("Dispatch() did not set DispatchedAt")
	}

	queue, err := env.service.RuntimeQueue(ctx, env.bot)
	if err != nil {
		t.Fatalf("RuntimeQueue() error = %v", err)
	}
	if len(queue) != 1 || queue[0].ID != task.ID {
		t.Fatalf("RuntimeQueue() = %#v, want task %s", queue, task.ID)
	}

	claimed, err := env.service.Claim(ctx, env.bot, task.ID, nil)
	if err != nil {
		t.Fatalf("Claim() error = %v", err)
	}
	if claimed.ClaimedAt == nil {
		t.Fatal("Claim() did not set ClaimedAt")
	}

	resultPayload := model.JSONMap{"summary": "done", "count": float64(2)}
	submitted, err := env.service.RuntimeResult(ctx, env.bot, task.ID, RuntimeTaskResultRequest{Result: resultPayload})
	if err != nil {
		t.Fatalf("RuntimeResult() error = %v", err)
	}
	if submitted.Status != model.TaskStatusAwaitingReview {
		t.Fatalf("RuntimeResult() status = %q, want awaiting_review", submitted.Status)
	}
	if submitted.Progress != 100 {
		t.Fatalf("RuntimeResult() progress = %d, want 100", submitted.Progress)
	}
	if submitted.Result["summary"] != "done" {
		t.Fatalf("RuntimeResult() result = %#v, want summary=done", submitted.Result)
	}

	accepted, err := env.service.Accept(ctx, env.owner.ID, task.ID, UserTaskActionRequest{})
	if err != nil {
		t.Fatalf("Accept() error = %v", err)
	}
	if accepted.Status != model.TaskStatusCompleted {
		t.Fatalf("Accept() status = %q, want completed", accepted.Status)
	}
	if accepted.ReviewedAt == nil || accepted.ReviewedBy == nil || *accepted.ReviewedBy != env.owner.ID {
		t.Fatalf("Accept() review fields = reviewed_at:%v reviewed_by:%v", accepted.ReviewedAt, accepted.ReviewedBy)
	}
	if len(accepted.Events) == 0 || accepted.Events[0].EventType != "task.accepted" {
		t.Fatalf("Accept() latest event = %#v, want task.accepted", accepted.Events)
	}
}

func TestTaskRejectRedispatchAndCancelFlow(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	ctx := context.Background()

	task := createClaimedRuntimeTask(t, env)
	if _, err := env.service.RuntimeResult(ctx, env.bot, task.ID, RuntimeTaskResultRequest{Result: model.JSONMap{"summary": "needs work"}}); err != nil {
		t.Fatalf("RuntimeResult() error = %v", err)
	}
	rejected, err := env.service.Reject(ctx, env.owner.ID, task.ID, UserTaskActionRequest{LatestStatusNote: stringPtr("revise")})
	if err != nil {
		t.Fatalf("Reject() error = %v", err)
	}
	if rejected.Status != model.TaskStatusRejected {
		t.Fatalf("Reject() status = %q, want rejected", rejected.Status)
	}
	if rejected.ReviewedAt == nil || rejected.ReviewedBy == nil {
		t.Fatalf("Reject() review fields = reviewed_at:%v reviewed_by:%v", rejected.ReviewedAt, rejected.ReviewedBy)
	}

	redispatched, err := env.service.Dispatch(ctx, env.owner.ID, task.ID, UserTaskActionRequest{})
	if err != nil {
		t.Fatalf("Dispatch() after reject error = %v", err)
	}
	if redispatched.Status != model.TaskStatusClaimed {
		t.Fatalf("Dispatch() after reject status = %q, want claimed", redispatched.Status)
	}
	if redispatched.ReviewedAt != nil || redispatched.Result != nil {
		t.Fatalf("Dispatch() after reject did not clear review/result fields: reviewed_at=%v result=%#v", redispatched.ReviewedAt, redispatched.Result)
	}

	cancelled, err := env.service.Cancel(ctx, env.owner.ID, task.ID, UserTaskActionRequest{LatestStatusNote: stringPtr("stop")})
	if err != nil {
		t.Fatalf("Cancel() error = %v", err)
	}
	if cancelled.Status != model.TaskStatusCancelled {
		t.Fatalf("Cancel() status = %q, want cancelled", cancelled.Status)
	}
	if cancelled.ActualEndAt == nil {
		t.Fatal("Cancel() did not set ActualEndAt")
	}
}

func TestTaskRetryFailedAndCancelledFlow(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	ctx := context.Background()

	failedTask := createClaimedRuntimeTask(t, env)
	if _, err := env.service.RuntimeFail(ctx, env.bot, failedTask.ID, RuntimeTaskFailRequest{LatestStatusNote: stringPtr("boom")}); err != nil {
		t.Fatalf("RuntimeFail() error = %v", err)
	}
	retriedFailed, err := env.service.Retry(ctx, env.owner.ID, failedTask.ID, UserTaskActionRequest{})
	if err != nil {
		t.Fatalf("Retry() failed task error = %v", err)
	}
	if retriedFailed.Status != model.TaskStatusClaimed || retriedFailed.Error != nil || retriedFailed.ClaimedAt != nil {
		t.Fatalf("Retry() failed task = status:%q error:%#v claimed_at:%v, want claimed with cleared runtime fields", retriedFailed.Status, retriedFailed.Error, retriedFailed.ClaimedAt)
	}

	cancelledTask := createClaimedRuntimeTask(t, env)
	if _, err := env.service.Cancel(ctx, env.owner.ID, cancelledTask.ID, UserTaskActionRequest{Note: stringPtr("stop")}); err != nil {
		t.Fatalf("Cancel() error = %v", err)
	}
	retriedCancelled, err := env.service.Retry(ctx, env.owner.ID, cancelledTask.ID, UserTaskActionRequest{})
	if err != nil {
		t.Fatalf("Retry() cancelled task error = %v", err)
	}
	if retriedCancelled.Status != model.TaskStatusClaimed || retriedCancelled.ActualEndAt != nil {
		t.Fatalf("Retry() cancelled task = status:%q actual_end:%v, want claimed with cleared actual end", retriedCancelled.Status, retriedCancelled.ActualEndAt)
	}
	if len(retriedCancelled.Events) == 0 || retriedCancelled.Events[0].EventType != "task.retried" {
		t.Fatalf("Retry() latest event = %#v, want task.retried", retriedCancelled.Events)
	}
}

func TestTaskUpdateCanClearAssignee(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	task, err := env.service.Create(context.Background(), env.owner.ID, CreateTaskRequest{
		Title:         "assigned task",
		AssigneeBotID: &env.bot.ID,
	})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	req := UpdateTaskRequest{}
	if err := req.UnmarshalJSON([]byte(`{"assignee_bot_id":null}`)); err != nil {
		t.Fatalf("UnmarshalJSON() error = %v", err)
	}
	updated, err := env.service.Update(context.Background(), env.owner.ID, task.ID, req)
	if err != nil {
		t.Fatalf("Update() error = %v", err)
	}
	if updated.AssigneeBotID != nil {
		t.Fatalf("Update() assignee = %v, want nil", updated.AssigneeBotID)
	}
	if updated.Status != model.TaskStatusAvailable {
		t.Fatalf("Update() status = %q, want available", updated.Status)
	}
}

func TestRuntimeCreateChildTaskRecordsParent(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	ctx := context.Background()
	parent, err := env.service.Create(ctx, env.owner.ID, CreateTaskRequest{Title: "parent task"})
	if err != nil {
		t.Fatalf("Create() parent error = %v", err)
	}

	child, err := env.service.RuntimeCreate(ctx, env.bot, CreateTaskRequest{
		Title:        "child task",
		ParentTaskID: &parent.ID,
	})
	if err != nil {
		t.Fatalf("RuntimeCreate() child error = %v", err)
	}
	if child.ParentTaskID == nil || *child.ParentTaskID != parent.ID {
		t.Fatalf("RuntimeCreate() parent id = %v, want %s", child.ParentTaskID, parent.ID)
	}
	if len(child.Events) == 0 || child.Events[0].Payload["parent_task_id"] != parent.ID.String() {
		t.Fatalf("RuntimeCreate() created event payload = %#v, want parent task id", child.Events)
	}
}

func TestRuntimeFailWritesStructuredError(t *testing.T) {
	env := newTaskServiceTestEnv(t)
	task := createClaimedRuntimeTask(t, env)

	failed, err := env.service.RuntimeFail(context.Background(), env.bot, task.ID, RuntimeTaskFailRequest{
		LatestStatusNote: stringPtr("boom"),
	})
	if err != nil {
		t.Fatalf("RuntimeFail() error = %v", err)
	}
	if failed.Status != model.TaskStatusFailed {
		t.Fatalf("RuntimeFail() status = %q, want failed", failed.Status)
	}
	if failed.Error["message"] != "boom" {
		t.Fatalf("RuntimeFail() error payload = %#v, want message=boom", failed.Error)
	}
}

type taskServiceTestEnv struct {
	service *TaskService
	owner   *model.User
	bot     *model.Bot
}

func newTaskServiceTestEnv(t *testing.T) *taskServiceTestEnv {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := createTaskServiceTestSchema(db); err != nil {
		t.Fatalf("create test schema: %v", err)
	}
	owner := &model.User{
		ID:           uuid.New(),
		Username:     "owner-" + uuid.NewString(),
		Email:        uuid.NewString() + "@example.test",
		PasswordHash: "hash",
		Status:       model.UserStatusActive,
	}
	if err := db.Create(owner).Error; err != nil {
		t.Fatalf("create owner: %v", err)
	}
	bot := &model.Bot{
		ID:      uuid.New(),
		OwnerID: owner.ID,
		Name:    "worker",
		BotType: model.BotTypeService,
		Status:  model.BotStatusEnabled,
	}
	if err := db.Create(bot).Error; err != nil {
		t.Fatalf("create bot: %v", err)
	}
	taskRepo := repository.NewTaskRepository(db)
	botRepo := repository.NewBotRepository(db)
	return &taskServiceTestEnv{
		service: NewTaskService(taskRepo, botRepo),
		owner:   owner,
		bot:     bot,
	}
}

func createTaskServiceTestSchema(db *gorm.DB) error {
	statements := []string{
		`CREATE TABLE users (
			id TEXT PRIMARY KEY,
			username TEXT NOT NULL UNIQUE,
			email TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			nickname TEXT,
			avatar_url TEXT,
			status INTEGER NOT NULL DEFAULT 1,
			is_deleted INTEGER NOT NULL DEFAULT 0,
			last_login_at DATETIME,
			last_login_ip TEXT,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			deleted_at DATETIME
		)`,
		`CREATE TABLE bots (
			id TEXT PRIMARY KEY,
			owner_id TEXT NOT NULL,
			name TEXT NOT NULL,
			description TEXT,
			avatar_url TEXT,
			bot_type TEXT NOT NULL DEFAULT 'general',
			status INTEGER NOT NULL DEFAULT 1,
			is_public INTEGER NOT NULL DEFAULT 0,
			config JSON,
			mqtt_topic TEXT,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			deleted_at DATETIME
		)`,
		`CREATE TABLE tasks (
			id TEXT PRIMARY KEY,
			owner_id TEXT NOT NULL,
			title TEXT NOT NULL,
			description TEXT,
			priority TEXT NOT NULL DEFAULT 'normal',
			status TEXT NOT NULL DEFAULT 'pending',
			parent_task_id TEXT,
			assignee_bot_id TEXT,
			estimated_start_at DATETIME,
			estimated_end_at DATETIME,
			actual_start_at DATETIME,
			actual_end_at DATETIME,
			progress INTEGER NOT NULL DEFAULT 0,
			latest_status_note TEXT,
			result JSON,
			error JSON,
			dispatched_at DATETIME,
			claimed_at DATETIME,
			reviewed_at DATETIME,
			reviewed_by TEXT,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			deleted_at DATETIME
		)`,
		`CREATE TABLE task_dependencies (
			id TEXT PRIMARY KEY,
			task_id TEXT NOT NULL,
			depends_on_task_id TEXT NOT NULL,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(task_id, depends_on_task_id)
		)`,
		`CREATE TABLE task_events (
			id TEXT PRIMARY KEY,
			task_id TEXT NOT NULL,
			actor_type TEXT NOT NULL,
			actor_id TEXT,
			event_type TEXT NOT NULL DEFAULT 'status_changed',
			status TEXT NOT NULL,
			progress INTEGER NOT NULL DEFAULT 0,
			note TEXT,
			payload JSON,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			return err
		}
	}
	return nil
}

func createClaimedRuntimeTask(t *testing.T, env *taskServiceTestEnv) *model.Task {
	t.Helper()
	ctx := context.Background()
	task, err := env.service.Create(ctx, env.owner.ID, CreateTaskRequest{
		Title:         "runtime task",
		Status:        model.TaskStatusPending,
		AssigneeBotID: &env.bot.ID,
	})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if _, err := env.service.Dispatch(ctx, env.owner.ID, task.ID, UserTaskActionRequest{}); err != nil {
		t.Fatalf("Dispatch() error = %v", err)
	}
	claimed, err := env.service.Claim(ctx, env.bot, task.ID, nil)
	if err != nil {
		t.Fatalf("Claim() error = %v", err)
	}
	return claimed
}

func stringPtr(value string) *string {
	return &value
}
