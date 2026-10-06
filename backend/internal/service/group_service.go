package service

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
)

var (
	ErrGroupNotFound     = errors.New("group not found")
	ErrNotGroupOwner     = errors.New("you are not the owner of this group")
	ErrNotGroupMember    = errors.New("you are not a member of this group")
	ErrGroupFull         = errors.New("group has reached maximum members")
	ErrAlreadyMember     = errors.New("user is already a member of this group")
	ErrInvalidMemberRole = errors.New("invalid group member role")
	ErrAlreadyBotMember  = errors.New("bot is already a member of this group")
)

// GroupService handles group operations
type GroupService struct {
	groupRepo *repository.GroupRepository
	botRepo   *repository.BotRepository
	auditRepo *repository.AuditLogRepository
}

// NewGroupService creates a new group service
func NewGroupService(
	groupRepo *repository.GroupRepository,
	botRepo *repository.BotRepository,
	auditRepo *repository.AuditLogRepository,
) *GroupService {
	return &GroupService{
		groupRepo: groupRepo,
		botRepo:   botRepo,
		auditRepo: auditRepo,
	}
}

// CreateGroupRequest represents group creation request
type CreateGroupRequest struct {
	Name        string  `json:"name" binding:"required,min=1,max=128"`
	Description *string `json:"description"`
	AvatarURL   *string `json:"avatar_url"`
	MaxMembers  int     `json:"max_members"`
}

// UpdateGroupRequest represents group update request
type UpdateGroupRequest struct {
	Name        *string `json:"name"`
	Description *string `json:"description"`
	AvatarURL   *string `json:"avatar_url"`
	IsActive    *bool   `json:"is_active"`
	MaxMembers  *int    `json:"max_members"`
}

// Create creates a new group
func (s *GroupService) Create(ctx context.Context, req CreateGroupRequest, ownerID uuid.UUID, ip, userAgent string) (*model.Group, error) {
	group := &model.Group{
		Name:        req.Name,
		Description: req.Description,
		AvatarURL:   req.AvatarURL,
		OwnerID:     ownerID,
		IsActive:    true,
		MaxMembers:  req.MaxMembers,
	}
	if group.MaxMembers == 0 {
		group.MaxMembers = 500
	}
	if err := s.groupRepo.Create(ctx, group); err != nil {
		return nil, err
	}
	// Add owner as a member
	ownerMember := &model.GroupMember{
		GroupID:  group.ID,
		UserID:   ownerID,
		Role:     model.GroupRoleOwner,
		IsActive: true,
	}
	if err := s.groupRepo.AddMember(ctx, ownerMember); err != nil {
		return nil, err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &ownerID,
		GroupID:      &group.ID,
		Action:       string(model.AuditActionCreateGroup),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(201),
	})
	return group, nil
}

// GetByID returns a group by ID
func (s *GroupService) GetByID(ctx context.Context, id uuid.UUID) (*model.Group, error) {
	group, err := s.groupRepo.GetByID(ctx, id)
	if err != nil {
		return nil, ErrGroupNotFound
	}
	return group, nil
}

// ListByUser returns groups for a user
func (s *GroupService) ListByUser(ctx context.Context, userID uuid.UUID, page, pageSize int) ([]model.Group, int64, error) {
	return s.groupRepo.ListByUser(ctx, userID, page, pageSize)
}

// Update updates a group
func (s *GroupService) Update(ctx context.Context, groupID, userID uuid.UUID, req UpdateGroupRequest, ip, userAgent string) (*model.Group, error) {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return nil, ErrGroupNotFound
	}
	if group.OwnerID != userID {
		return nil, ErrNotGroupOwner
	}
	if req.Name != nil {
		group.Name = *req.Name
	}
	if req.Description != nil {
		group.Description = req.Description
	}
	if req.AvatarURL != nil {
		group.AvatarURL = req.AvatarURL
	}
	if req.IsActive != nil {
		group.IsActive = *req.IsActive
	}
	if req.MaxMembers != nil {
		group.MaxMembers = *req.MaxMembers
	}
	if err := s.groupRepo.Update(ctx, group); err != nil {
		return nil, err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &userID,
		GroupID:      &groupID,
		Action:       string(model.AuditActionUpdateGroup),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return group, nil
}

// Delete deletes a group
func (s *GroupService) Delete(ctx context.Context, groupID, userID uuid.UUID, ip, userAgent string) error {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return ErrGroupNotFound
	}
	if group.OwnerID != userID {
		return ErrNotGroupOwner
	}
	if err := s.groupRepo.Delete(ctx, groupID); err != nil {
		return err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &userID,
		GroupID:      &groupID,
		Action:       string(model.AuditActionDeleteGroup),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return nil
}

// --- Members ---

// AddMemberRequest represents adding a member request
type AddMemberRequest struct {
	UserID   *uuid.UUID            `json:"user_id"`
	BotID    *uuid.UUID            `json:"bot_id"`
	Role     model.GroupMemberRole `json:"role"`
	Nickname *string               `json:"nickname"`
}

// AddMember adds a user or bot to a group
func (s *GroupService) AddMember(ctx context.Context, groupID, requesterID uuid.UUID, req AddMemberRequest, ip, userAgent string) error {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return ErrGroupNotFound
	}
	if !group.IsActive {
		return errors.New("group is not active")
	}
	if err := s.ensureCanManageMembers(ctx, group, requesterID); err != nil {
		return err
	}

	if (req.UserID == nil) == (req.BotID == nil) {
		return ErrInvalidMemberRole
	}
	if req.Role == "" {
		req.Role = model.GroupRoleMember
	}
	if req.Role != model.GroupRoleMember && req.Role != model.GroupRoleAdmin {
		return ErrInvalidMemberRole
	}
	if req.Role == model.GroupRoleAdmin && (group.OwnerID != requesterID || req.BotID != nil) {
		return ErrNotGroupOwner
	}
	if req.UserID != nil {
		// Check if already a member
		exists, err := s.groupRepo.IsMember(ctx, groupID, *req.UserID)
		if err != nil {
			return err
		}
		if exists {
			return ErrAlreadyMember
		}
		// Check group capacity
		count, err := s.GetMemberCount(ctx, groupID)
		if err != nil {
			return err
		}
		if count >= int64(group.MaxMembers) {
			return ErrGroupFull
		}
		role := req.Role
		if role == "" {
			role = model.GroupRoleMember
		}
		member := &model.GroupMember{
			GroupID:  groupID,
			UserID:   *req.UserID,
			Role:     role,
			Nickname: req.Nickname,
			IsActive: true,
		}
		if err := s.groupRepo.AddMember(ctx, member); err != nil {
			return err
		}
		s.auditRepo.CreateAsync(&model.AuditLog{
			UserID:       &requesterID,
			GroupID:      &groupID,
			Action:       string(model.AuditActionAddMember),
			ResourceType: strPtr("user"),
			ResourceID:   req.UserID,
			IPAddress:    &ip,
			UserAgent:    &userAgent,
			ResponseCode: intPtr(200),
		})
	} else if req.BotID != nil {
		exists, err := s.groupRepo.IsBotMember(ctx, groupID, *req.BotID)
		if err != nil {
			return err
		}
		if exists {
			return ErrAlreadyBotMember
		}
		bot, err := s.botRepo.GetByID(ctx, *req.BotID)
		if err != nil {
			return ErrBotNotFound
		}
		if bot.OwnerID != requesterID {
			return ErrNotBotOwner
		}
		count, err := s.GetMemberCount(ctx, groupID)
		if err != nil {
			return err
		}
		if count >= int64(group.MaxMembers) {
			return ErrGroupFull
		}
		role := req.Role
		if role == "" {
			role = model.GroupRoleMember
		}
		botMember := &model.BotGroupMember{
			GroupID:  groupID,
			BotID:    *req.BotID,
			Role:     role,
			Nickname: req.Nickname,
			IsActive: true,
		}
		if err := s.groupRepo.AddBotMember(ctx, botMember); err != nil {
			return err
		}
		s.auditRepo.CreateAsync(&model.AuditLog{
			UserID:       &requesterID,
			GroupID:      &groupID,
			Action:       string(model.AuditActionAddMember),
			ResourceType: strPtr("bot"),
			ResourceID:   req.BotID,
			IPAddress:    &ip,
			UserAgent:    &userAgent,
			ResponseCode: intPtr(200),
		})
	}
	return nil
}

func (s *GroupService) ensureCanManageMembers(ctx context.Context, group *model.Group, requesterID uuid.UUID) error {
	if group.OwnerID == requesterID {
		return nil
	}

	member, err := s.groupRepo.GetMember(ctx, group.ID, requesterID)
	if err != nil {
		return ErrNotGroupMember
	}
	if member.Role != model.GroupRoleAdmin {
		return ErrGroupAdminRequired
	}
	return nil
}

// RemoveMember removes a user or bot from a group
func (s *GroupService) RemoveMember(ctx context.Context, groupID, targetID, requesterID uuid.UUID, ip, userAgent string) error {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return ErrGroupNotFound
	}
	// Only owner or admin can remove members; target can remove themselves
	member, err := s.groupRepo.GetMember(ctx, groupID, targetID)
	if err != nil {
		return ErrNotGroupMember
	}
	requesterMember, err := s.groupRepo.GetMember(ctx, groupID, requesterID)
	if err != nil {
		return ErrNotGroupMember
	}
	if group.OwnerID != requesterID && requesterMember.Role != model.GroupRoleAdmin && targetID != requesterID {
		return ErrNotGroupOwner
	}
	if targetID == group.OwnerID || member.Role == model.GroupRoleOwner {
		return ErrNotGroupOwner
	}
	if member.Role == model.GroupRoleAdmin && requesterID != group.OwnerID && requesterID != targetID {
		return ErrNotGroupOwner
	}
	if err := s.groupRepo.RemoveMember(ctx, groupID, targetID); err != nil {
		return err
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &requesterID,
		GroupID:      &groupID,
		Action:       string(model.AuditActionRemoveMember),
		ResourceType: strPtr("user"),
		ResourceID:   &targetID,
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return nil
}

// ListMembers returns all members of a group
func (s *GroupService) ListMembers(ctx context.Context, groupID uuid.UUID) ([]model.GroupMember, []model.BotGroupMember, error) {
	_, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return nil, nil, ErrGroupNotFound
	}
	users, err := s.groupRepo.ListMembers(ctx, groupID)
	if err != nil {
		return nil, nil, err
	}
	bots, err := s.groupRepo.ListBotMembers(ctx, groupID)
	if err != nil {
		return nil, nil, err
	}
	return users, bots, nil
}

func (s *GroupService) GetMemberCount(ctx context.Context, groupID uuid.UUID) (int64, error) {
	userCount, err := s.groupRepo.CountMembers(ctx, groupID)
	if err != nil {
		return 0, err
	}
	botCount, err := s.groupRepo.CountBotMembers(ctx, groupID)
	if err != nil {
		return 0, err
	}
	return userCount + botCount, nil
}

func (s *GroupService) GetMemberCounts(ctx context.Context, groupIDs []uuid.UUID) (map[uuid.UUID]int64, error) {
	counts := make(map[uuid.UUID]int64, len(groupIDs))
	for _, groupID := range groupIDs {
		count, err := s.GetMemberCount(ctx, groupID)
		if err != nil {
			return nil, err
		}
		counts[groupID] = count
	}
	return counts, nil
}

// CanRead checks metadata and member lists as well as message history.
func (s *GroupService) CanRead(ctx context.Context, groupID, userID uuid.UUID) error {
	group, err := s.GetByID(ctx, groupID)
	if err != nil {
		return err
	}
	if group.OwnerID == userID {
		return nil
	}
	member, err := s.groupRepo.IsMember(ctx, groupID, userID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotGroupMember
	}
	return nil
}
