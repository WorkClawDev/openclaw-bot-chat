package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"testing"
)

func TestArtifactOwnershipAndVersion(t *testing.T) {
	db, _, bot := runRepoFixture(t)
	if err := db.AutoMigrate(&model.AgentArtifact{}); err != nil {
		t.Fatal(err)
	}
	r := NewAgentArtifactRepository(db)
	ctx := context.Background()
	run := uuid.New()
	first := &model.AgentArtifact{OwnerID: bot.OwnerID, BotID: bot.ID, RunID: run, AssetID: uuid.New(), FileName: "result.md", SHA256: "first"}
	if err := r.Create(ctx, first); err != nil {
		t.Fatal(err)
	}
	same, err := r.Find(ctx, bot.OwnerID, run, "result.md", "first")
	if err != nil || same.ID != first.ID {
		t.Fatal("dedup lookup", err)
	}
	second := &model.AgentArtifact{OwnerID: bot.OwnerID, BotID: bot.ID, RunID: run, AssetID: uuid.New(), FileName: "result.md", SHA256: "second"}
	if err = r.Create(ctx, second); err != nil || second.Version != 2 {
		t.Fatal("version", err)
	}
	if _, err = r.Get(ctx, uuid.New(), first.ID); err == nil {
		t.Fatal("other owner accessed artifact")
	}
}
