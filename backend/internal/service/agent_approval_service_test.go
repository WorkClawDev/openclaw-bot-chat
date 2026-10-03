package service

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"strings"
	"testing"
	"time"
)

func TestAgentApprovalOwnerAndParameterBinding(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.AgentApproval{}); err != nil {
		t.Fatal(err)
	}
	repo := repository.NewAgentApprovalRepository(db)
	s := NewAgentApprovalService(repo)
	bot := &model.Bot{ID: uuid.New(), OwnerID: uuid.New()}
	ctx := context.Background()
	request := AgentApprovalRequest{RunID: "chat:message", Tool: "publish", ParameterHash: strings.Repeat("a", 64), Arguments: model.JSONMap{"text": "hello"}}
	row, err := s.Request(ctx, bot, request)
	if err != nil {
		t.Fatal(err)
	}
	same, err := s.Request(ctx, bot, request)
	if err != nil || same.ID != row.ID {
		t.Fatal("duplicate approval created", err)
	}
	if s.Decide(ctx, uuid.New(), row.ID, true) == nil {
		t.Fatal("another owner approved")
	}
	if _, err = s.Get(ctx, &model.Bot{ID: uuid.New(), OwnerID: bot.OwnerID}, row.ID); err == nil {
		t.Fatal("another bot read approval")
	}
	if err = s.Decide(ctx, bot.OwnerID, row.ID, true); err != nil {
		t.Fatal(err)
	}
	if s.Decide(ctx, bot.OwnerID, row.ID, false) == nil {
		t.Fatal("decision changed")
	}
	request.ParameterHash = strings.Repeat("b", 64)
	different, err := s.Request(ctx, bot, request)
	if err != nil || different.ID == row.ID || different.Status != "pending" {
		t.Fatal("modified args reused approval", err)
	}
	db.Model(&model.AgentApproval{}).Where("id = ?", different.ID).Update("expires_at", time.Now().Add(-time.Second))
	if s.Decide(ctx, bot.OwnerID, different.ID, true) == nil {
		t.Fatal("expired approval accepted")
	}
}
