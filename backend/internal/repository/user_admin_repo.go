package repository

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

var (
	ErrAdminRequired        = errors.New("administrator role required")
	ErrLastAdmin            = errors.New("at least one active administrator is required")
	ErrSelfAdminChange      = errors.New("ask another administrator to change your own access")
	ErrInvalidAccountAccess = errors.New("invalid role or account status")
)

func (r *UserRepository) ListAccounts(ctx context.Context, search string, page, size int) ([]model.User, int64, error) {
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 100 {
		size = 20
	}
	query := r.db.WithContext(ctx).Model(&model.User{}).Where("is_deleted = false")
	if search = strings.TrimSpace(search); search != "" {
		pattern := "%" + strings.ToLower(search) + "%"
		query = query.Where("LOWER(username) LIKE ? OR LOWER(email) LIKE ?", pattern, pattern)
	}
	var total int64
	var users []model.User
	if err := query.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	err := query.Order("created_at DESC, id").Offset((page - 1) * size).Limit(size).Find(&users).Error
	return users, total, err
}

func (r *UserRepository) UpdateAccountAccess(ctx context.Context, actorID, targetID uuid.UUID, role *model.UserRole, status *model.UserStatus, ip string) (*model.User, error) {
	if (role == nil && status == nil) || (role != nil && *role != model.UserRoleUser && *role != model.UserRoleAdmin) ||
		(status != nil && *status != model.UserStatusInactive && *status != model.UserStatusActive && *status != model.UserStatusBanned) {
		return nil, ErrInvalidAccountAccess
	}
	var user model.User
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// All administrator changes take these locks in the same order. Recheck
		// the actor after acquiring them, including concurrent demotion requests.
		var admins []model.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("role = ? AND status = ? AND is_deleted = false", model.UserRoleAdmin, model.UserStatusActive).Order("id").Find(&admins).Error; err != nil {
			return err
		}
		var actor model.User
		if tx.First(&actor, "id = ?", actorID).Error != nil || !actor.IsActive() || actor.Role != model.UserRoleAdmin {
			return ErrAdminRequired
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, "id = ? AND is_deleted = false", targetID).Error; err != nil {
			return err
		}
		beforeRole, beforeStatus := user.Role, user.Status
		if role != nil {
			user.Role = *role
		}
		if status != nil {
			user.Status = *status
		}
		if targetID == actorID && (user.Role != model.UserRoleAdmin || !user.IsActive()) {
			return ErrSelfAdminChange
		}
		if beforeRole == model.UserRoleAdmin && beforeStatus == model.UserStatusActive && (user.Role != model.UserRoleAdmin || !user.IsActive()) && len(admins) <= 1 {
			return ErrLastAdmin
		}
		// Bump on both suspension and reactivation under the row lock. A token
		// minted before either transition can never become valid again.
		if user.Status != beforeStatus {
			user.TokenVersion++
		}
		if err := tx.Model(&user).Updates(map[string]interface{}{"role": user.Role, "status": user.Status, "token_version": user.TokenVersion}).Error; err != nil {
			return err
		}
		resource := "user"
		return tx.Create(&model.AuditLog{EventID: uuid.New(), UserID: &actorID, ResourceID: &targetID, ResourceType: &resource,
			Action: "update_account_access", IPAddress: &ip, Metadata: model.JSONMap{"previous_role": beforeRole, "role": user.Role, "previous_status": beforeStatus, "status": user.Status}}).Error
	})
	return &user, err
}
