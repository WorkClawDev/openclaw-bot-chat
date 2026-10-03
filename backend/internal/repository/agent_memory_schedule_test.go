package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"testing"
	"time"
)

func memoryFixture(t *testing.T) (*AgentMemoryRepository, *AgentScheduleRepository, *model.Bot) {
	db, _, bot := runRepoFixture(t)
	for _, sql := range []string{`CREATE TABLE bots(id text primary key,owner_id text,deleted_at datetime)`, `CREATE TABLE tasks(id text primary key,owner_id text,title text,description text,priority text,status text,parent_task_id text,assignee_bot_id text,estimated_start_at datetime,estimated_end_at datetime,actual_start_at datetime,actual_end_at datetime,progress integer,latest_status_note text,result text,error text,dispatched_at datetime,claimed_at datetime,reviewed_at datetime,reviewed_by text,created_at datetime,updated_at datetime,deleted_at datetime)`, `CREATE TABLE task_events(id text primary key,task_id text,actor_type text,actor_id text,event_type text,status text,progress integer,note text,payload text,created_at datetime)`} {
		if err := db.Exec(sql).Error; err != nil {
			t.Fatal(err)
		}
	}
	db.Exec("INSERT INTO bots (id,owner_id) VALUES (?,?)", bot.ID, bot.OwnerID)
	if err := db.AutoMigrate(&model.AgentMemory{}, &model.AgentMemoryRevision{}, &model.AgentContext{}, &model.AgentSchedule{}, &model.AgentScheduleOccurrence{}); err != nil {
		t.Fatal(err)
	}
	return NewAgentMemoryRepository(db), NewAgentScheduleRepository(db), bot
}
func TestConfirmedMemoryDeletionInvalidatesContext(t *testing.T) {
	r, _, bot := memoryFixture(t)
	ctx := context.Background()
	row := &model.AgentMemory{BotID: bot.ID, Scope: "personal", Content: "use CNY", Source: "user message", Confirmed: true}
	if err := r.Save(ctx, bot.OwnerID, row); err != nil {
		t.Fatal(err)
	}
	unconfirmed := *row
	unconfirmed.ID = uuid.Nil
	unconfirmed.Confirmed = false
	if r.Save(ctx, bot.OwnerID, &unconfirmed) == nil {
		t.Fatal("unconfirmed memory accepted")
	}
	if r.Save(ctx, uuid.New(), row) == nil {
		t.Fatal("other owner updated")
	}
	r.db.Create(&model.AgentContext{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, Scope: "old", Data: model.JSONMap{"summary": "use CNY"}})
	revision, _ := r.Revision(ctx, bot.ID)
	if err := r.Delete(ctx, bot.OwnerID, row.ID); err != nil {
		t.Fatal(err)
	}
	reopened := NewAgentMemoryRepository(r.db)
	rows, _ := reopened.List(ctx, bot.OwnerID, &bot.ID, "other session")
	latest, _ := reopened.Revision(ctx, bot.ID)
	var count int64
	r.db.Model(&model.AgentContext{}).Count(&count)
	if len(rows) != 0 || latest <= revision || count != 0 {
		t.Fatal("deleted memory persisted", rows, latest, count)
	}
}
func TestScheduleRestartDedupAndMissedPolicy(t *testing.T) {
	_, r, bot := memoryFixture(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 3, 0, 0, 0, 0, time.UTC)
	row := &model.AgentSchedule{BotID: bot.ID, Title: "Daily report", Prompt: "produce result", Timezone: "Asia/Shanghai", Recurrence: "daily", MissedPolicy: "once", NextAt: now.AddDate(0, 0, -3)}
	if err := r.Save(ctx, bot.OwnerID, row); err != nil {
		t.Fatal(err)
	}
	if err := r.Tick(ctx, now); err != nil {
		t.Fatal(err)
	}
	if err := NewAgentScheduleRepository(r.db).Tick(ctx, now); err != nil {
		t.Fatal(err)
	}
	var count int64
	r.db.Model(&model.Task{}).Count(&count)
	if count != 1 {
		t.Fatal("missed occurrences duplicated", count)
	}
	rows, _ := r.List(ctx, bot.OwnerID)
	if !rows[0].NextAt.After(now) || rows[0].LastTaskID == nil {
		t.Fatal("next occurrence not persisted")
	}
	if r.Action(ctx, uuid.New(), row.ID, "pause") == nil {
		t.Fatal("other owner paused")
	}
	if err := r.Action(ctx, bot.OwnerID, row.ID, "pause"); err != nil {
		t.Fatal(err)
	}
	if err := r.Tick(ctx, now.AddDate(0, 0, 1)); err != nil {
		t.Fatal(err)
	}
	r.db.Model(&model.Task{}).Count(&count)
	if count != 1 {
		t.Fatal("paused schedule triggered")
	}
	skip := &model.AgentSchedule{BotID: bot.ID, Title: "skip", Prompt: "work", Timezone: "UTC", Recurrence: "once", MissedPolicy: "skip", NextAt: now.Add(-time.Hour)}
	if err := r.Save(ctx, bot.OwnerID, skip); err != nil {
		t.Fatal(err)
	}
	if err := r.Tick(ctx, now); err != nil {
		t.Fatal(err)
	}
	r.db.Model(&model.Task{}).Count(&count)
	if count != 1 {
		t.Fatal("skip produced task")
	}
}
func TestSchedulePreservesLocalHourAcrossDST(t *testing.T) {
	loc, _ := time.LoadLocation("America/New_York")
	before := time.Date(2026, 3, 7, 9, 0, 0, 0, loc)
	next, err := nextScheduleTime(before, "daily", loc.String())
	if err != nil || next.In(loc).Hour() != 9 || next.Sub(before) != 23*time.Hour {
		t.Fatal("DST wall clock", next, err)
	}
}
