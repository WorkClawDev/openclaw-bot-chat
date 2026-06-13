package response

import (
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

type DocumentResponse struct {
	ID                   uuid.UUID            `json:"id"`
	OwnerID              uuid.UUID            `json:"owner_id"`
	URL                  string               `json:"url"`
	Title                string               `json:"title"`
	Summary              string               `json:"summary"`
	Body                 string               `json:"body,omitempty"`
	DocumentType         model.DocumentType   `json:"document_type"`
	Source               model.DocumentSource `json:"source"`
	Status               model.DocumentStatus `json:"status"`
	SourceBotID          *uuid.UUID           `json:"source_bot_id,omitempty"`
	SourceConversationID *string              `json:"source_conversation_id,omitempty"`
	SourceMessageID      *uuid.UUID           `json:"source_message_id,omitempty"`
	Metadata             model.JSONMap        `json:"metadata,omitempty"`
	CreatedAt            time.Time            `json:"created_at"`
	UpdatedAt            time.Time            `json:"updated_at"`
}

func NewDocumentResponse(document *model.Document, includeBody bool) *DocumentResponse {
	if document == nil {
		return nil
	}
	response := &DocumentResponse{
		ID:                   document.ID,
		OwnerID:              document.OwnerID,
		URL:                  DocumentURL(document.ID),
		Title:                document.Title,
		Summary:              document.Summary,
		DocumentType:         document.DocumentType,
		Source:               document.Source,
		Status:               document.Status,
		SourceBotID:          document.SourceBotID,
		SourceConversationID: document.SourceConversationID,
		SourceMessageID:      document.SourceMessageID,
		Metadata:             document.Metadata,
		CreatedAt:            document.CreatedAt,
		UpdatedAt:            document.UpdatedAt,
	}
	if includeBody {
		response.Body = document.Body
	}
	return response
}

func DocumentURL(documentID uuid.UUID) string {
	return "/documents/" + documentID.String()
}

func NewDocumentResponses(documents []model.Document) []DocumentResponse {
	responses := make([]DocumentResponse, 0, len(documents))
	for i := range documents {
		responses = append(responses, *NewDocumentResponse(&documents[i], false))
	}
	return responses
}
