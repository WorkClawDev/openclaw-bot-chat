package repository

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestAccountAdministrationRejectsEscalationAndAuditsChanges(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sql, _ := db.DB()
	t.Cleanup(func() { sql.Close() })
	for _, statement := range []string{
		`CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT, email TEXT, role TEXT, status INTEGER, is_deleted BOOLEAN DEFAULT false, created_at DATETIME, updated_at DATETIME, deleted_at DATETIME)`,
		`CREATE TABLE audit_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT, user_id TEXT, bot_id TEXT, group_id TEXT, action TEXT, resource_type TEXT, resource_id TEXT, ip_address TEXT, user_agent TEXT, request_method TEXT, request_path TEXT, request_body TEXT, response_code INTEGER, error_message TEXT, metadata TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`,
	} {
		if err := db.Exec(statement).Error; err != nil {
			t.Fatal(err)
		}
	}
	admin, ordinary := uuid.New(), uuid.New()
	db.Exec("INSERT INTO users(id, username, role, status) VALUES(?, 'operator', 'admin', 1), (?, 'member', 'user', 1)", admin, ordinary)
	repo := NewUserRepository(db)
	ctx := context.Background()
	adminRole, userRole := model.UserRoleAdmin, model.UserRoleUser
	banned := model.UserStatusBanned
	if _, err := repo.UpdateAccountAccess(ctx, ordinary, ordinary, &adminRole, nil, ""); !errors.Is(err, ErrAdminRequired) {
		t.Fatalf("self escalation: %v", err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, admin, admin, &userRole, nil, ""); !errors.Is(err, ErrSelfAdminChange) {
		t.Fatalf("self demotion: %v", err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, admin, admin, nil, &banned, ""); !errors.Is(err, ErrSelfAdminChange) {
		t.Fatalf("self suspension: %v", err)
	}
	invalid := model.UserRole("superuser")
	if _, err := repo.UpdateAccountAccess(ctx, admin, ordinary, &invalid, nil, ""); !errors.Is(err, ErrInvalidAccountAccess) {
		t.Fatalf("invalid role: %v", err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, admin, ordinary, &adminRole, nil, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, ordinary, admin, &userRole, nil, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, admin, ordinary, nil, &banned, ""); !errors.Is(err, ErrAdminRequired) {
		t.Fatalf("demoted actor: %v", err)
	}
	if _, err := repo.UpdateAccountAccess(ctx, ordinary, admin, nil, &banned, ""); err != nil {
		t.Fatal(err)
	}
	var count int64
	db.Model(&model.AuditLog{}).Count(&count)
	if count != 3 {
		t.Fatalf("expected three audit records, got %d", count)
	}
	users, total, err := repo.ListAccounts(ctx, "member", 1, 20)
	if err != nil || total != 1 || len(users) != 1 || users[0].ID != ordinary {
		t.Fatalf("account search: %v %d %v", users, total, err)
	}
}
