package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"github.com/openclaw-bot-chat/backend/pkg/password"
)

func TestReactivationDoesNotReviveRefreshTokens(t *testing.T) {
	env := newPhoneAuthServiceTestEnv(t)
	users := env.service.userRepo
	auth := NewAuthService(users, env.service.auditRepo, env.service.jwtManager)
	ctx := context.Background()
	hash, err := password.Hash("regression-password-92!")
	if err != nil {
		t.Fatal(err)
	}
	admin := &model.User{ID: uuid.New(), Username: "operator", Role: model.UserRoleAdmin, Status: model.UserStatusActive}
	user := &model.User{ID: uuid.New(), Username: "member", PasswordHash: &hash, Status: model.UserStatusActive}
	for _, account := range []*model.User{admin, user} {
		if err := users.Create(ctx, account); err != nil {
			t.Fatal(err)
		}
	}
	login := func() *TokenResponse {
		t.Helper()
		tokens, _, err := auth.Login(ctx, LoginRequest{Username: user.Username, Password: "regression-password-92!"}, "", "")
		if err != nil {
			t.Fatal(err)
		}
		return tokens
	}
	before := login()
	if _, err := auth.RefreshToken(ctx, before.RefreshToken); err != nil {
		t.Fatal(err)
	}
	banned, active := model.UserStatusBanned, model.UserStatusActive
	for i, status := range []*model.UserStatus{&banned, &active} {
		updated, err := users.UpdateAccountAccess(ctx, admin.ID, user.ID, nil, status, "")
		if err != nil || updated.TokenVersion != int64(i+1) {
			t.Fatalf("status transition: %+v %v", updated, err)
		}
		auth = NewAuthService(users, env.service.auditRepo, env.service.jwtManager)
		_, err = auth.RefreshToken(ctx, before.RefreshToken)
		want := ErrUserBanned
		if i == 1 {
			want = jwt.ErrInvalidToken
		}
		if !errors.Is(err, want) {
			t.Fatalf("old refresh after transition %d: %v", i, err)
		}
	}
	after := login()
	claims, err := env.service.jwtManager.ValidateAccessToken(after.AccessToken)
	if err != nil || claims.TokenVersion != 2 {
		t.Fatalf("new login: %+v %v", claims, err)
	}
	if _, err := auth.RefreshToken(ctx, after.RefreshToken); err != nil {
		t.Fatal(err)
	}
	promoted := model.UserRoleAdmin
	updated, err := users.UpdateAccountAccess(ctx, admin.ID, user.ID, &promoted, nil, "")
	if err != nil || updated.TokenVersion != 2 {
		t.Fatalf("role-only edit should preserve current tokens: %+v %v", updated, err)
	}
}
