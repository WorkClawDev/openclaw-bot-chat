package handler

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

func TestDocumentOwnerForBotRequestOnlyTrustsBotOwnerDM(t *testing.T) {
	botOwnerID := uuid.New()
	otherUserID := uuid.New()
	botID := uuid.New()

	ownerDM := fmt.Sprintf("chat/dm/user/%s/bot/%s", botOwnerID, botID)
	if got := documentOwnerForBotRequest(botOwnerID, botID, ownerDM); got != botOwnerID {
		t.Fatalf("documentOwnerForBotRequest(owner dm) = %s, want %s", got, botOwnerID)
	}

	otherDM := fmt.Sprintf("chat/dm/user/%s/bot/%s", otherUserID, botID)
	if got := documentOwnerForBotRequest(botOwnerID, botID, otherDM); got != botOwnerID {
		t.Fatalf("documentOwnerForBotRequest(other dm) = %s, want fallback owner %s", got, botOwnerID)
	}

	groupTopic := fmt.Sprintf("chat/group/%s", uuid.New())
	if got := documentOwnerForBotRequest(botOwnerID, botID, groupTopic); got != botOwnerID {
		t.Fatalf("documentOwnerForBotRequest(group) = %s, want fallback owner %s", got, botOwnerID)
	}
}

func TestBuildBotDocumentURLMessageUsesPlainTextURL(t *testing.T) {
	botID := uuid.New()
	ownerID := uuid.New()
	documentID := uuid.New()
	document := &model.Document{
		ID:           documentID,
		OwnerID:      ownerID,
		Title:        "AI Plan",
		Summary:      "A useful plan",
		DocumentType: "markdown",
		Source:       "bot",
		UpdatedAt:    time.Now(),
	}
	bot := &model.Bot{
		ID:      botID,
		OwnerID: ownerID,
		Name:    "Writer",
	}

	message := buildBotDocumentURLMessage(bot, "chat/dm/user/u1/bot/b1", document)
	if message.MsgType != model.MsgTypeText {
		t.Fatalf("MsgType = %q, want text", message.MsgType)
	}
	if !strings.Contains(message.Content, "/documents/"+documentID.String()) {
		t.Fatalf("Content = %q, want document url", message.Content)
	}
	if message.Metadata["document_url"] != "/documents/"+documentID.String() {
		t.Fatalf("document_url metadata = %#v", message.Metadata["document_url"])
	}
	if message.Metadata["document_title"] != "AI Plan" {
		t.Fatalf("document_title metadata = %#v", message.Metadata["document_title"])
	}
	if message.Metadata["document_summary"] != "A useful plan" {
		t.Fatalf("document_summary metadata = %#v", message.Metadata["document_summary"])
	}
	if message.Metadata["document_type"] != "markdown" {
		t.Fatalf("document_type metadata = %#v", message.Metadata["document_type"])
	}
	if message.Metadata["document_updated_at"] == nil {
		t.Fatalf("document_updated_at metadata is missing")
	}
}
