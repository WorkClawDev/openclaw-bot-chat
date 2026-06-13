package service

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"gorm.io/gorm"
)

var (
	ErrDocumentNotFound     = errors.New("document not found")
	ErrDocumentInvalidTitle = errors.New("document title is required")
	ErrDocumentInvalidBody  = errors.New("document body is too large")
)

type DocumentService struct {
	docRepo *repository.DocumentRepository
}

func NewDocumentService(docRepo *repository.DocumentRepository) *DocumentService {
	return &DocumentService{docRepo: docRepo}
}

type CreateDocumentRequest struct {
	Title                string                 `json:"title"`
	Body                 string                 `json:"body"`
	Summary              string                 `json:"summary"`
	DocumentType         string                 `json:"document_type"`
	Source               string                 `json:"source"`
	ConversationID       string                 `json:"conversation_id"`
	SourceConversationID string                 `json:"source_conversation_id"`
	Metadata             map[string]interface{} `json:"metadata"`
}

type UpdateDocumentRequest struct {
	Title   *string `json:"title"`
	Body    *string `json:"body"`
	Summary *string `json:"summary"`
}

func (s *DocumentService) Create(ctx context.Context, ownerID uuid.UUID, req CreateDocumentRequest) (*model.Document, error) {
	title := normalizeDocumentTitle(req.Title, req.Body)
	if title == "" {
		return nil, ErrDocumentInvalidTitle
	}
	body := strings.TrimRight(req.Body, "\n")
	if err := validateDocumentBody(body); err != nil {
		return nil, err
	}
	docType := normalizeDocumentType(req.DocumentType)
	source := normalizeDocumentSource(req.Source)
	summary := normalizeDocumentSummary(req.Summary, body)
	conversationID := strings.TrimSpace(firstNonEmpty(req.SourceConversationID, req.ConversationID))

	document := &model.Document{
		OwnerID:      ownerID,
		Title:        title,
		Summary:      summary,
		Body:         body,
		DocumentType: docType,
		Source:       source,
		Status:       model.DocumentStatusActive,
		Metadata:     model.JSONMap(req.Metadata),
	}
	if conversationID != "" {
		document.SourceConversationID = &conversationID
	}
	if err := s.docRepo.Create(ctx, document); err != nil {
		return nil, err
	}
	return document, nil
}

func (s *DocumentService) CreateFromBot(ctx context.Context, ownerID uuid.UUID, botID uuid.UUID, req CreateDocumentRequest) (*model.Document, error) {
	req.Source = string(model.DocumentSourceBot)
	document, err := s.Create(ctx, ownerID, req)
	if err != nil {
		return nil, err
	}
	document.SourceBotID = &botID
	if err := s.docRepo.Update(ctx, document); err != nil {
		return nil, err
	}
	return document, nil
}

func (s *DocumentService) List(ctx context.Context, ownerID uuid.UUID, limit int) ([]model.Document, error) {
	return s.docRepo.ListByOwner(ctx, ownerID, limit)
}

func (s *DocumentService) Get(ctx context.Context, ownerID, documentID uuid.UUID) (*model.Document, error) {
	document, err := s.docRepo.GetActiveByIDAndOwner(ctx, documentID, ownerID)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrDocumentNotFound
		}
		return nil, err
	}
	return document, nil
}

func (s *DocumentService) Update(ctx context.Context, ownerID, documentID uuid.UUID, req UpdateDocumentRequest) (*model.Document, error) {
	document, err := s.Get(ctx, ownerID, documentID)
	if err != nil {
		return nil, err
	}
	if req.Title != nil {
		title := strings.TrimSpace(*req.Title)
		if title == "" {
			return nil, ErrDocumentInvalidTitle
		}
		document.Title = title
	}
	if req.Body != nil {
		body := strings.TrimRight(*req.Body, "\n")
		if err := validateDocumentBody(body); err != nil {
			return nil, err
		}
		document.Body = body
		if req.Summary == nil {
			document.Summary = normalizeDocumentSummary("", body)
		}
	}
	if req.Summary != nil {
		document.Summary = normalizeDocumentSummary(*req.Summary, document.Body)
	}
	if err := s.docRepo.Update(ctx, document); err != nil {
		return nil, err
	}
	return document, nil
}

func (s *DocumentService) UpdateFromBot(ctx context.Context, ownerID, botID, documentID uuid.UUID, req UpdateDocumentRequest) (*model.Document, error) {
	document, err := s.Get(ctx, ownerID, documentID)
	if err != nil {
		return nil, err
	}
	if document.SourceBotID != nil && *document.SourceBotID != botID {
		return nil, ErrDocumentNotFound
	}
	return s.Update(ctx, ownerID, documentID, req)
}

func (s *DocumentService) Archive(ctx context.Context, ownerID, documentID uuid.UUID) error {
	if err := s.docRepo.Archive(ctx, documentID, ownerID); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrDocumentNotFound
		}
		return err
	}
	return nil
}

func (s *DocumentService) SetSourceMessage(ctx context.Context, ownerID, documentID, messageID uuid.UUID) (*model.Document, error) {
	document, err := s.Get(ctx, ownerID, documentID)
	if err != nil {
		return nil, err
	}
	document.SourceMessageID = &messageID
	if err := s.docRepo.Update(ctx, document); err != nil {
		return nil, err
	}
	return document, nil
}

func normalizeDocumentTitle(title string, body string) string {
	trimmed := strings.TrimSpace(title)
	if trimmed != "" {
		return truncateRunes(trimmed, 255)
	}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(line, "#"))
		if line != "" {
			return truncateRunes(line, 80)
		}
	}
	return "Untitled Document"
}

func normalizeDocumentSummary(summary string, body string) string {
	trimmed := strings.TrimSpace(summary)
	if trimmed == "" {
		trimmed = strings.Join(strings.Fields(body), " ")
	}
	return truncateRunes(trimmed, 180)
}

func normalizeDocumentType(value string) model.DocumentType {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case string(model.DocumentTypeMarkdown), "":
		return model.DocumentTypeMarkdown
	default:
		return model.DocumentTypeMarkdown
	}
}

func normalizeDocumentSource(value string) model.DocumentSource {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case string(model.DocumentSourceBot):
		return model.DocumentSourceBot
	default:
		return model.DocumentSourceUser
	}
}

func validateDocumentBody(body string) error {
	if len(body) > 2*1024*1024 {
		return ErrDocumentInvalidBody
	}
	return nil
}

func truncateRunes(value string, limit int) string {
	if limit <= 0 || utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return strings.TrimSpace(string(runes[:limit]))
}
