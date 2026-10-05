package repository

import (
	"context"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
)

// GroupRepository handles group database operations
type GroupRepository struct {
	db *gorm.DB
}

func NewGroupRepository(db *gorm.DB) *GroupRepository {
	return &GroupRepository{db: db}
}

func (r *GroupRepository) Create(ctx context.Context, group *model.Group) error {
	return r.db.WithContext(ctx).Create(group).Error
}

func (r *GroupRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Group, error) {
	var group model.Group
	err := r.db.WithContext(ctx).Preload("Owner").Where("id = ?", id).First(&group).Error
	if err != nil {
		return nil, err
	}
	return &group, nil
}

func (r *GroupRepository) ListByUser(ctx context.Context, userID uuid.UUID, page, pageSize int) ([]model.Group, int64, error) {
	var groups []model.Group
	var total int64

	subQuery := r.db.WithContext(ctx).Model(&model.GroupMember{}).Select("group_id").Where("user_id = ? AND is_active = true", userID)
	query := r.db.WithContext(ctx).Model(&model.Group{}).Where("id IN (?) OR owner_id = ?", subQuery, userID)
	if err := query.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	offset := (page - 1) * pageSize
	if err := query.Preload("Owner").Order("created_at DESC, id ASC").Offset(offset).Limit(pageSize).Find(&groups).Error; err != nil {
		return nil, 0, err
	}
	return groups, total, nil
}

func (r *GroupRepository) ListByBot(ctx context.Context, botID uuid.UUID) ([]model.Group, error) {
	var groups []model.Group
	subQuery := r.db.WithContext(ctx).
		Model(&model.BotGroupMember{}).
		Select("group_id").
		Where("bot_id = ? AND is_active = true", botID)

	err := r.db.WithContext(ctx).
		Preload("Owner").
		Where("is_active = true AND id IN (?)", subQuery).
		Order("created_at DESC").
		Find(&groups).Error
	return groups, err
}

func (r *GroupRepository) Update(ctx context.Context, group *model.Group) error {
	return r.db.WithContext(ctx).Save(group).Error
}

func (r *GroupRepository) Delete(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).Delete(&model.Group{}, "id = ?", id).Error
}

func (r *GroupRepository) IsOwner(ctx context.Context, groupID, userID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.Group{}).Where("id = ? AND owner_id = ?", groupID, userID).Count(&count).Error
	return count > 0, err
}

// --- GroupMember ---

func (r *GroupRepository) AddMember(ctx context.Context, member *model.GroupMember) error {
	return r.db.WithContext(ctx).Create(member).Error
}

func (r *GroupRepository) RemoveMember(ctx context.Context, groupID, userID uuid.UUID) error {
	return r.db.WithContext(ctx).Delete(&model.GroupMember{}, "group_id = ? AND user_id = ?", groupID, userID).Error
}

func (r *GroupRepository) GetMember(ctx context.Context, groupID, userID uuid.UUID) (*model.GroupMember, error) {
	var member model.GroupMember
	err := r.db.WithContext(ctx).Preload("User").Where("group_id = ? AND user_id = ? AND is_active = true", groupID, userID).First(&member).Error
	if err != nil {
		return nil, err
	}
	return &member, nil
}

func (r *GroupRepository) ListMembers(ctx context.Context, groupID uuid.UUID) ([]model.GroupMember, error) {
	var members []model.GroupMember
	err := r.db.WithContext(ctx).Preload("User").Where("group_id = ? AND is_active = true", groupID).Find(&members).Error
	return members, err
}

func (r *GroupRepository) CountMembers(ctx context.Context, groupID uuid.UUID) (int64, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.GroupMember{}).Where("group_id = ? AND is_active = true", groupID).Count(&count).Error
	return count, err
}

func (r *GroupRepository) IsMember(ctx context.Context, groupID, userID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.GroupMember{}).Where("group_id = ? AND user_id = ? AND is_active = true", groupID, userID).Count(&count).Error
	return count > 0, err
}

// --- BotGroupMember ---

func (r *GroupRepository) AddBotMember(ctx context.Context, botMember *model.BotGroupMember) error {
	return r.db.WithContext(ctx).Create(botMember).Error
}

func (r *GroupRepository) RemoveBotMember(ctx context.Context, groupID, botID uuid.UUID) error {
	return r.db.WithContext(ctx).Delete(&model.BotGroupMember{}, "group_id = ? AND bot_id = ?", groupID, botID).Error
}

func (r *GroupRepository) ListBotMembers(ctx context.Context, groupID uuid.UUID) ([]model.BotGroupMember, error) {
	var members []model.BotGroupMember
	err := r.db.WithContext(ctx).Preload("Bot").Where("group_id = ? AND is_active = true", groupID).Find(&members).Error
	return members, err
}

func (r *GroupRepository) IsBotMember(ctx context.Context, groupID, botID uuid.UUID) (bool, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.BotGroupMember{}).Where("group_id = ? AND bot_id = ? AND is_active = true", groupID, botID).Count(&count).Error
	return count > 0, err
}

func (r *GroupRepository) CountBotMembers(ctx context.Context, groupID uuid.UUID) (int64, error) {
	var count int64
	err := r.db.WithContext(ctx).Model(&model.BotGroupMember{}).Where("group_id = ? AND is_active = true", groupID).Count(&count).Error
	return count, err
}
