package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"sync"
	"testing"
	"time"
)

func runRepoFixture(t *testing.T) (*gorm.DB, *AgentRunRepository, *model.Bot) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := db.DB()
	raw.SetMaxOpenConns(1)
	t.Cleanup(func() { raw.Close() })
	if err = db.AutoMigrate(&model.AgentRun{}, &model.AgentRunEvent{}, &model.AgentApproval{}, &model.AgentInbox{}); err != nil {
		t.Fatal(err)
	}
	return db, NewAgentRunRepository(db), &model.Bot{ID: uuid.New(), OwnerID: uuid.New()}
}
func TestRunCompetitionFencingAndWaiting(t *testing.T) {
	db, r, bot := runRepoFixture(t)
	ctx := context.Background()
	run, err := r.Create(ctx, bot, "chat:message", "conversation", nil, model.JSONMap{})
	if err != nil {
		t.Fatal(err)
	}
	same, err := r.Create(ctx, bot, "chat:message", "conversation", nil, nil)
	if err != nil || same.ID != run.ID {
		t.Fatal("duplicate run", err)
	}
	var wg sync.WaitGroup
	results := make(chan *model.AgentRun, 2)
	for _, worker := range []string{"worker-one", "worker-two"} {
		wg.Add(1)
		go func(worker string) {
			defer wg.Done()
			row, err := r.Claim(ctx, bot, run.ID, worker, time.Now().UnixMilli())
			if err == nil {
				results <- row
			}
		}(worker)
	}
	wg.Wait()
	close(results)
	if len(results) != 1 {
		t.Fatal("multiple lease winners", len(results))
	}
	first := <-results
	db.Model(&model.AgentRun{}).Where("id = ?", run.ID).Update("lease_until", 0)
	second, err := r.Claim(ctx, bot, run.ID, "replacement", time.Now().UnixMilli())
	if err != nil || second.Fence <= first.Fence {
		t.Fatal("lease did not fence replacement", err)
	}
	if r.Transition(ctx, bot, run.ID, first.WorkerID, first.Fence, "succeeded", nil, "") == nil {
		t.Fatal("old worker wrote result")
	}
	var wrote bool
	if r.Fenced(ctx, bot, run.ID, first.WorkerID, first.Fence, false, func(ctx context.Context) error { wrote = true; return nil }) == nil || wrote {
		t.Fatal("old worker entered journal write")
	}
	if err = r.Transition(ctx, bot, run.ID, second.WorkerID, second.Fence, "waiting_input", nil, "Need a file"); err != nil {
		t.Fatal(err)
	}
	waiting, _ := r.Get(ctx, bot.OwnerID, &bot.ID, run.ID)
	if waiting.LeaseUntil != 0 {
		t.Fatal("waiting retained lease")
	}
	if r.UserAction(ctx, uuid.New(), run.ID, "resume", "data") == nil {
		t.Fatal("other owner resumed run")
	}
	if err = r.UserAction(ctx, bot.OwnerID, run.ID, "resume", "provided data"); err != nil {
		t.Fatal(err)
	}
	resumed, err := r.Claim(ctx, bot, run.ID, "replacement", time.Now().UnixMilli())
	if err != nil || resumed.Input["supplement"] != "provided data" {
		t.Fatal("input lost", err)
	}
	if err = r.UserAction(ctx, bot.OwnerID, run.ID, "cancel", ""); err != nil {
		t.Fatal(err)
	}
	if r.Event(ctx, bot, run.ID, "replacement", resumed.Fence, "tool_intent", nil) == nil {
		t.Fatal("cancel allowed new tool")
	}
	if err = r.Transition(ctx, bot, run.ID, "replacement", resumed.Fence, "cancelled", nil, "stopped"); err != nil {
		t.Fatal(err)
	}
	events, err := r.Events(ctx, bot.OwnerID, run.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	for i, event := range events {
		if event.Seq != int64(i+1) {
			t.Fatal("event sequence gap", event.Seq)
		}
	}
}
func TestEventOutboxRecoversAndMarksDelivery(t *testing.T) {
	_, r, bot := runRepoFixture(t)
	ctx := context.Background()
	run, err := r.Create(ctx, bot, "chat:notice", "", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := r.Claim(ctx, bot, run.ID, "worker", time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Event(ctx, bot, run.ID, "worker", claimed.Fence, "assistant_delta", model.JSONMap{"text": "actual"}); err != nil {
		t.Fatal(err)
	}
	rows, err := r.PendingNotices(ctx)
	if err != nil || len(rows) == 0 {
		t.Fatal("outbox absent", err)
	}
	reopened := NewAgentRunRepository(r.db)
	again, _ := reopened.PendingNotices(ctx)
	if len(again) != len(rows) {
		t.Fatal("outbox lost on restart")
	}
	for _, row := range rows {
		if row.OwnerID != bot.OwnerID {
			t.Fatal("notification owner")
		}
		if err = reopened.NoticeDelivered(ctx, row.ID); err != nil {
			t.Fatal(err)
		}
	}
	remaining, _ := r.PendingNotices(ctx)
	if len(remaining) != 0 {
		t.Fatal("notice not acknowledged")
	}
}

func TestCancelledCrashedWorkerIsReapedAndFenced(t *testing.T) {
	db, r, bot := runRepoFixture(t)
	ctx := context.Background()
	run, err := r.Create(ctx, bot, "crashed", "", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	active, err := r.Claim(ctx, bot, run.ID, "lost", time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	db.Model(&model.AgentRun{}).Where("id = ?", run.ID).Updates(map[string]interface{}{"cancel_requested": true, "lease_until": 0})
	if err = r.ReapCancelled(ctx, time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	row, _ := r.Get(ctx, bot.OwnerID, &bot.ID, run.ID)
	if row.Status != "cancelled" || row.Fence <= active.Fence || row.LeaseUntil != 0 {
		t.Fatal("crashed cancellation not finalized", row)
	}
	if _, err = r.Claim(ctx, bot, run.ID, "replacement", time.Now().UnixMilli()); err == nil {
		t.Fatal("cancelled run restarted")
	}
	if err = r.ReapCancelled(ctx, time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
}

func TestAgentHealthIsOwnerScopedAndCountsActualSteps(t *testing.T) {
	db, r, bot := runRepoFixture(t)
	if err := db.AutoMigrate(&model.AgentToolCall{}); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	first, _ := r.Create(ctx, bot, "own", "", nil, nil)
	other := &model.Bot{ID: uuid.New(), OwnerID: uuid.New()}
	r.Create(ctx, other, "other", "", nil, nil)
	db.Model(&model.AgentRun{}).Where("id = ?", first.ID).Update("steps", 7)
	data, err := r.Health(ctx, bot.OwnerID)
	if err != nil {
		t.Fatal(err)
	}
	if data["executed_steps"].(int64) != 7 || data["run_counts"].(map[string]int64)["queued"] != 1 {
		t.Fatal("diagnostics included another owner or fake usage", data)
	}
}
