package service

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"testing"
	"time"
)

func TestAgentTaskResultRequiresUserReview(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err = createTaskServiceTestSchema(db); err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.AgentRun{}, &model.AgentRunEvent{}, &model.AgentApproval{}); err != nil {
		t.Fatal(err)
	}
	owner := model.User{ID: uuid.New(), Username: "disposable-fixture", Status: model.UserStatusActive}
	if err = db.Create(&owner).Error; err != nil {
		t.Fatal(err)
	}
	bot := model.Bot{ID: uuid.New(), OwnerID: owner.ID, Name: "fixture", Status: model.BotStatusEnabled}
	if err = db.Create(&bot).Error; err != nil {
		t.Fatal(err)
	}
	task := model.Task{ID: uuid.New(), OwnerID: owner.ID, Title: "actual work", Status: model.TaskStatusClaimed, AssigneeBotID: &bot.ID, Priority: model.TaskPriorityNormal}
	if err = db.Create(&task).Error; err != nil {
		t.Fatal(err)
	}
	r := repository.NewAgentRunRepository(db)
	ctx := context.Background()
	run, err := r.Create(ctx, &bot, "task", "", &task.ID, model.JSONMap{})
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := r.Claim(ctx, &bot, run.ID, "worker", time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Transition(ctx, &bot, run.ID, "worker", claimed.Fence, "succeeded", model.JSONMap{"content": "actual evidence"}, "review result"); err != nil {
		t.Fatal(err)
	}
	service := NewTaskService(repository.NewTaskRepository(db), repository.NewBotRepository(db))
	result, err := service.Get(ctx, owner.ID, task.ID)
	if err != nil || result.Status != model.TaskStatusAwaitingReview {
		t.Fatal("agent bypassed review", err)
	}
	accepted, err := service.Accept(ctx, owner.ID, task.ID, UserTaskActionRequest{})
	if err := r.UserAction(ctx, owner.ID, run.ID, "cancel", ""); err == nil {
		t.Fatal("completed result could be cancelled through run API")
	}
	if err != nil || accepted.Status != model.TaskStatusCompleted {
		t.Fatal("user review did not complete task", err)
	}
}

func TestTaskCancellationStopsFencedToolsAndSurvivesWorkerCrash(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err = createTaskServiceTestSchema(db); err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.AgentRun{}, &model.AgentRunEvent{}, &model.AgentApproval{}); err != nil {
		t.Fatal(err)
	}
	bot := &model.Bot{ID: uuid.New(), OwnerID: uuid.New()}
	task := model.Task{ID: uuid.New(), OwnerID: bot.OwnerID, Title: "cancel source", Status: model.TaskStatusClaimed, AssigneeBotID: &bot.ID, Priority: model.TaskPriorityNormal}
	if err = db.Create(&task).Error; err != nil {
		t.Fatal(err)
	}
	r := repository.NewAgentRunRepository(db)
	ctx := context.Background()
	run, err := r.Create(ctx, bot, "task", "", &task.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	active, err := r.Claim(ctx, bot, run.ID, "worker", time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	db.Model(&task).Update("status", model.TaskStatusCancelled)
	wrote := false
	if r.Fenced(ctx, bot, run.ID, "worker", active.Fence, false, func(context.Context) error { wrote = true; return nil }) == nil || wrote {
		t.Fatal("cancelled Task permitted new tool")
	}
	latest, err := r.Heartbeat(ctx, bot, run.ID, "worker", active.Fence)
	if err != nil || !latest.CancelRequested {
		t.Fatal("cancel not propagated", err)
	}
	saved, _ := r.Get(ctx, bot.OwnerID, &bot.ID, run.ID)
	if !saved.CancelRequested {
		t.Fatal("cancel flag not durable")
	}
	db.Model(&model.AgentRun{}).Where("id = ?", run.ID).Update("lease_until", 0)
	if err = r.ReapCancelled(ctx, time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	stopped, _ := r.Get(ctx, bot.OwnerID, &bot.ID, run.ID)
	if stopped.Status != "cancelled" {
		t.Fatal("cancelled Task run survived crashed worker")
	}
}
