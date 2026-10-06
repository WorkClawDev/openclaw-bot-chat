package service

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestRealtimeTopicsAllowFirstMessageOnlyToOwnedEnabledBots(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := db.DB()
	raw.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = raw.Close() })
	for _, statement := range []string{
		`CREATE TABLE users (id text PRIMARY KEY,status integer,is_deleted boolean,deleted_at datetime)`,
		`CREATE TABLE bots (id text PRIMARY KEY, owner_id text, status integer, deleted_at datetime, created_at datetime)`,
		`CREATE TABLE messages (conversation_id text, sender_id text, bot_id text, is_deleted boolean, created_at datetime)`,
		`CREATE TABLE groups (id text PRIMARY KEY, owner_id text, deleted_at datetime, created_at datetime, is_active boolean)`,
		`CREATE TABLE group_members (group_id text, user_id text, is_active boolean)`,
	} {
		if err := db.Exec(statement).Error; err != nil {
			t.Fatal(err)
		}
	}
	owner, other := uuid.New(), uuid.New()
	for _, id := range []uuid.UUID{owner, other} {
		if err := db.Exec("INSERT INTO users VALUES (?,1,false,NULL)", id).Error; err != nil {
			t.Fatal(err)
		}
	}
	enabled, disabled, foreign, deleted := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	for _, row := range []struct {
		id, owner uuid.UUID
		status    int
		deleted   any
	}{
		{enabled, owner, 1, nil}, {disabled, owner, 0, nil}, {foreign, other, 1, nil}, {deleted, owner, 1, "2026-01-01"},
	} {
		if err := db.Exec("INSERT INTO bots (id,owner_id,status,deleted_at) VALUES (?,?,?,?)", row.id, row.owner, row.status, row.deleted).Error; err != nil {
			t.Fatal(err)
		}
	}
	service := NewMessageService(repository.NewMessageRepository(db), repository.NewBotRepository(db), repository.NewGroupRepository(db), nil, nil, nil)
	want := []string{fmt.Sprintf("chat/dm/user/%s/bot/%s", owner, enabled)}
	topics, err := service.ListUserRealtimeTopics(context.Background(), owner)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(topics, want) {
		t.Fatalf("first-chat topics = %v, want %v", topics, want)
	}
	// Creating history must not duplicate the same scoped subscription.
	if err := db.Exec("INSERT INTO messages VALUES (?,?,?,?,CURRENT_TIMESTAMP)", want[0], owner, enabled, false).Error; err != nil {
		t.Fatal(err)
	}
	topics, err = service.ListUserRealtimeTopics(context.Background(), owner)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(topics, want) {
		t.Fatalf("existing-chat topics = %v, want %v", topics, want)
	}
}
