package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"testing"
)

func TestAgentJournalPersistenceAndUncertainTool(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.AgentInbox{}, &model.AgentContext{}, &model.AgentToolCall{}); err != nil {
		t.Fatal(err)
	}
	r := NewAgentJournalRepository(db)
	ctx := context.Background()
	bot := &model.Bot{ID: uuid.New(), OwnerID: uuid.New()}
	var first uuid.UUID
	for i := 0; i < 100; i++ {
		row, err := r.Accept(ctx, bot, "message", model.JSONMap{"body": "work"})
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = row.ID
		}
		if first != row.ID {
			t.Fatal("duplicate inbox")
		}
	}
	if err = r.Finish(ctx, bot, "message", "completed", model.JSONMap{"message_id": "stable-reply"}); err != nil {
		t.Fatal(err)
	}
	pending, err := r.Pending(ctx, bot)
	if err != nil || len(pending) != 1 {
		t.Fatal("outbox disappeared", err)
	}
	if err = r.Delivered(ctx, bot, "message"); err != nil {
		t.Fatal(err)
	}
	pending, err = r.Pending(ctx, bot)
	if err != nil || len(pending) != 0 {
		t.Fatal("delivered outbox still pending", err)
	}
	if err = r.SaveContext(ctx, bot, "session", model.JSONMap{"memory": "preference"}); err != nil {
		t.Fatal(err)
	}
	data, err := r.Context(ctx, bot, "session")
	if err != nil || data["memory"] != "preference" {
		t.Fatal("context not restored", err)
	}
	_, err = r.PrepareTool(ctx, bot, "run", "key", "external", false)
	if err != nil {
		t.Fatal(err)
	}
	tool, err := r.PrepareTool(ctx, bot, "run", "key", "external", false)
	if err != nil || tool.Status != "uncertain" {
		t.Fatal("non-idempotent tool blindly retried", err)
	}
	other, err := r.Context(ctx, &model.Bot{ID: uuid.New(), OwnerID: bot.OwnerID}, "session")
	if err != nil || len(other) != 0 {
		t.Fatal("cross bot context leak", err)
	}
}

func TestUncertainToolRequiresOwnerEvidenceBeforeResume(t *testing.T) {
	db, runs, bot := runRepoFixture(t)
	if err := db.AutoMigrate(&model.AgentToolCall{}); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	run, err := runs.Create(ctx, bot, "reconcile", "", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	db.Model(&model.AgentRun{}).Where("id = ?", run.ID).Update("status", "waiting_input")
	r := NewAgentJournalRepository(db)
	call, err := r.PrepareTool(ctx, bot, run.ID.String(), "effect", "external", false)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := r.UncertainTools(ctx, bot.OwnerID)
	if err != nil || len(rows) != 1 {
		t.Fatal("missing uncertain call", err)
	}
	if r.Reconcile(ctx, uuid.New(), call.ID, "completed", "actual provider receipt") == nil {
		t.Fatal("other owner reconciled")
	}
	if r.Reconcile(ctx, bot.OwnerID, call.ID, "completed", "") == nil {
		t.Fatal("no evidence accepted")
	}
	if err = r.Reconcile(ctx, bot.OwnerID, call.ID, "completed", "provider receipt #fixture confirms success"); err != nil {
		t.Fatal(err)
	}
	prior, err := r.PrepareTool(ctx, bot, run.ID.String(), "effect", "external", false)
	if err != nil || prior.Status != "completed" {
		t.Fatal("verified result lost", err)
	}
	next, err := r.PrepareTool(ctx, bot, run.ID.String(), "not-applied", "external", false)
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Reconcile(ctx, bot.OwnerID, next.ID, "not_applied", "provider records confirm no operation"); err != nil {
		t.Fatal(err)
	}
	retry, err := r.PrepareTool(ctx, bot, run.ID.String(), "not-applied", "external", false)
	if err != nil || retry.ID == next.ID {
		t.Fatal("verified no-effect could not retry", err)
	}
}
