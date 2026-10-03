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
