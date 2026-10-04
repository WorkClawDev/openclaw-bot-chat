package service

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestUserRealtimeTopicsIncludeOwnedBotsBeforeFirstMessage(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw.Close() })
	if err := createTaskServiceTestSchema(db); err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE messages (conversation_id TEXT, sender_id TEXT, bot_id TEXT, is_deleted BOOLEAN, created_at DATETIME)`,
		`CREATE TABLE groups (id TEXT, owner_id TEXT, is_active BOOLEAN, created_at DATETIME, deleted_at DATETIME)`,
		`CREATE TABLE group_members (group_id TEXT, user_id TEXT)`,
	} {
		if err := db.Exec(statement).Error; err != nil {
			t.Fatal(err)
		}
	}
	owner := uuid.New()
	bots := []model.Bot{
		{ID: uuid.New(), OwnerID: owner, Name: "new owned bot", Status: model.BotStatusEnabled},
		{ID: uuid.New(), OwnerID: uuid.New(), Name: "other owner's bot", Status: model.BotStatusEnabled},
		{ID: uuid.New(), OwnerID: owner, Name: "disabled bot", Status: model.BotStatusEnabled},
		{ID: uuid.New(), OwnerID: owner, Name: "deleted bot", Status: model.BotStatusEnabled},
	}
	if err := db.Create(&bots).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&bots[2]).Update("status", model.BotStatusDisabled).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Delete(&bots[3]).Error; err != nil {
		t.Fatal(err)
	}
	svc := NewMessageService(repository.NewMessageRepository(db), repository.NewBotRepository(db), repository.NewGroupRepository(db), nil, nil, nil)
	topics, err := svc.ListUserRealtimeTopics(context.Background(), owner)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{fmt.Sprintf("chat/dm/user/%s/bot/%s", owner, bots[0].ID)}
	if !reflect.DeepEqual(topics, want) {
		t.Fatalf("new bot must be reachable without history, without granting unrelated bots: got %v, want %v", topics, want)
	}
}
