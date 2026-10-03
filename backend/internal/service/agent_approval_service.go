package service

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"regexp"
	"strings"
	"time"
)

type AgentApprovalService struct {
	repo *repository.AgentApprovalRepository
}

func NewAgentApprovalService(repo *repository.AgentApprovalRepository) *AgentApprovalService {
	return &AgentApprovalService{repo: repo}
}

type AgentApprovalRequest struct {
	RunID         string        `json:"run_id"`
	Tool          string        `json:"tool"`
	ParameterHash string        `json:"parameter_hash"`
	Arguments     model.JSONMap `json:"arguments"`
}

func (s *AgentApprovalService) Request(ctx context.Context, bot *model.Bot, req AgentApprovalRequest) (*model.AgentApproval, error) {
	if bot == nil || strings.TrimSpace(req.RunID) == "" || len(req.RunID) > 128 || req.Tool == "" || len(req.Tool) > 128 || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(req.ParameterHash) {
		return nil, errors.New("invalid approval scope")
	}
	now := time.Now().UTC()
	return s.repo.Request(ctx, &model.AgentApproval{ID: uuid.New(), OwnerID: bot.OwnerID, BotID: bot.ID, RunID: req.RunID, Tool: req.Tool, ParameterHash: req.ParameterHash, Arguments: req.Arguments, Status: "pending", ExpiresAt: now.Add(15 * time.Minute), CreatedAt: now})
}
func (s *AgentApprovalService) List(ctx context.Context, owner uuid.UUID) ([]model.AgentApproval, error) {
	return s.repo.List(ctx, owner)
}
func (s *AgentApprovalService) Get(ctx context.Context, bot *model.Bot, id uuid.UUID) (*model.AgentApproval, error) {
	return s.repo.Get(ctx, bot.OwnerID, bot.ID, id)
}
func (s *AgentApprovalService) Decide(ctx context.Context, owner, id uuid.UUID, approved bool) error {
	status := "denied"
	if approved {
		status = "approved"
	}
	return s.repo.Decide(ctx, owner, id, status, time.Now().UTC())
}
