package service

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"github.com/openclaw-bot-chat/backend/pkg/password"
	"gorm.io/gorm"
)

var (
	ErrUserNotFound           = errors.New("user not found")
	ErrInvalidCredentials     = errors.New("invalid username or password")
	ErrMissingLoginIdentifier = errors.New("missing login identifier")
	ErrUserAlreadyExists      = errors.New("user already exists")
	ErrUsernameTaken          = errors.New("username already taken")
	ErrEmailTaken             = errors.New("email already taken")
	ErrIncorrectPassword      = errors.New("incorrect password")
	ErrWeakPassword           = errors.New("new password does not meet policy")
	ErrUserBanned             = errors.New("account has been suspended")
)

// AuthService handles authentication operations
type AuthService struct {
	userRepo   *repository.UserRepository
	auditRepo  *repository.AuditLogRepository
	jwtManager *jwt.Manager
}

// NewAuthService creates a new auth service
func NewAuthService(userRepo *repository.UserRepository, auditRepo *repository.AuditLogRepository, jwtManager *jwt.Manager) *AuthService {
	return &AuthService{
		userRepo:   userRepo,
		auditRepo:  auditRepo,
		jwtManager: jwtManager,
	}
}

// RegisterRequest represents a registration request
type RegisterRequest struct {
	Username string `json:"username" binding:"required,min=3,max=64"`
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required,min=8"`
}

// LoginRequest represents a login request
type LoginRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
	Password string `json:"password" binding:"required"`
}

// TokenResponse represents token response
type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	TokenType    string `json:"token_type"`
}

// RefreshRequest represents a token refresh request
type RefreshRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

type UpdateProfileRequest struct {
	Nickname  *string `json:"nickname"`
	Avatar    *string `json:"avatar"`
	AvatarURL *string `json:"avatar_url"`
}

type ChangePasswordRequest struct {
	OldPassword      string `json:"oldPassword"`
	NewPassword      string `json:"newPassword"`
	OldPasswordSnake string `json:"old_password"`
	NewPasswordSnake string `json:"new_password"`
}

// Register creates a new user account
func (s *AuthService) Register(ctx context.Context, req RegisterRequest, ip, userAgent string) (*TokenResponse, *model.User, error) {
	// Check if username exists
	exists, err := s.userRepo.ExistsByUsername(ctx, req.Username)
	if err != nil {
		return nil, nil, err
	}
	if exists {
		return nil, nil, ErrUsernameTaken
	}
	// Check if email exists
	exists, err = s.userRepo.ExistsByEmail(ctx, req.Email)
	if err != nil {
		return nil, nil, err
	}
	if exists {
		return nil, nil, ErrEmailTaken
	}
	// Hash password
	hashedPassword, err := password.Hash(req.Password)
	if err != nil {
		return nil, nil, err
	}
	// Create user
	email := strings.TrimSpace(req.Email)
	user := &model.User{
		Username:     req.Username,
		Email:        &email,
		PasswordHash: &hashedPassword,
		AuthProvider: "password",
		Status:       model.UserStatusActive,
	}
	if err := s.userRepo.Create(ctx, user); err != nil {
		return nil, nil, err
	}
	// Generate tokens
	accessToken, refreshToken, err := s.jwtManager.GenerateTokenPair(user.ID, user.Username)
	if err != nil {
		return nil, nil, err
	}
	// Audit log
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &user.ID,
		Action:       string(model.AuditActionRegister),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(201),
	})
	return &TokenResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    7200,
		TokenType:    "Bearer",
	}, user, nil
}

// Login authenticates a user and returns tokens
func (s *AuthService) Login(ctx context.Context, req LoginRequest, ip, userAgent string) (*TokenResponse, *model.User, error) {
	identifier := req.normalizedIdentifier()
	if identifier == "" {
		return nil, nil, ErrMissingLoginIdentifier
	}

	user, err := s.userRepo.GetByUsernameOrEmail(ctx, identifier)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, nil, ErrInvalidCredentials
		}
		return nil, nil, err
	}
	if user.Status == model.UserStatusBanned {
		return nil, nil, ErrUserBanned
	}
	if user.PasswordHash == nil || !password.Check(req.Password, *user.PasswordHash) {
		return nil, nil, ErrInvalidCredentials
	}
	// Update last login
	_ = s.userRepo.UpdateLastLogin(ctx, user.ID, ip)
	// Generate tokens
	accessToken, refreshToken, err := s.jwtManager.GenerateTokenPair(user.ID, user.Username)
	if err != nil {
		return nil, nil, err
	}
	// Audit log
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &user.ID,
		Action:       string(model.AuditActionLogin),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
	return &TokenResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    7200,
		TokenType:    "Bearer",
	}, user, nil
}

func (r LoginRequest) normalizedIdentifier() string {
	email := strings.TrimSpace(r.Email)
	if email != "" {
		return email
	}
	return strings.TrimSpace(r.Username)
}

// RefreshToken refreshes access token using refresh token
func (s *AuthService) RefreshToken(ctx context.Context, refreshTokenStr string) (*TokenResponse, error) {
	claims, err := s.jwtManager.ValidateRefreshToken(refreshTokenStr)
	if err != nil {
		return nil, err
	}
	user, err := s.userRepo.GetByID(ctx, claims.UserID)
	if err != nil {
		return nil, ErrUserNotFound
	}
	accessToken, newRefreshToken, err := s.jwtManager.GenerateTokenPair(user.ID, user.Username)
	if err != nil {
		return nil, err
	}
	return &TokenResponse{
		AccessToken:  accessToken,
		RefreshToken: newRefreshToken,
		ExpiresIn:    7200,
		TokenType:    "Bearer",
	}, nil
}

func (s *AuthService) GetByID(ctx context.Context, userID uuid.UUID) (*model.User, error) {
	user, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return nil, ErrUserNotFound
	}
	return user, nil
}

func (s *AuthService) UpdateProfile(ctx context.Context, userID uuid.UUID, req UpdateProfileRequest, ip, userAgent string) (*model.User, error) {
	user, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return nil, ErrUserNotFound
	}

	updates := map[string]interface{}{}
	if req.Nickname != nil {
		trimmedNickname := strings.TrimSpace(*req.Nickname)
		if trimmedNickname == "" {
			updates["nickname"] = nil
			user.Nickname = nil
		} else {
			updates["nickname"] = trimmedNickname
			user.Nickname = &trimmedNickname
		}
	}

	avatarValue := req.Avatar
	if req.AvatarURL != nil {
		avatarValue = req.AvatarURL
	}
	if avatarValue != nil {
		trimmedAvatar := strings.TrimSpace(*avatarValue)
		if trimmedAvatar == "" {
			updates["avatar_url"] = nil
			user.AvatarURL = nil
		} else {
			updates["avatar_url"] = trimmedAvatar
			user.AvatarURL = &trimmedAvatar
		}
	}

	if len(updates) == 0 {
		return user, nil
	}

	if err := s.userRepo.UpdateFields(ctx, userID, updates); err != nil {
		return nil, err
	}

	updatedUser, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &userID,
		Action:       string(model.AuditActionUpdateProfile),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})

	return updatedUser, nil
}

func (s *AuthService) ChangePassword(ctx context.Context, userID uuid.UUID, req ChangePasswordRequest, ip, userAgent string) error {
	oldPassword, newPassword := req.normalizedPasswords()
	if oldPassword == "" || newPassword == "" {
		return ErrWeakPassword
	}
	if len(newPassword) < 8 {
		return ErrWeakPassword
	}

	user, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return ErrUserNotFound
	}
	if user.PasswordHash == nil || !password.Check(oldPassword, *user.PasswordHash) {
		return ErrIncorrectPassword
	}

	hashedPassword, err := password.Hash(newPassword)
	if err != nil {
		return err
	}
	if err := s.userRepo.UpdateFields(ctx, userID, map[string]interface{}{
		"password_hash": &hashedPassword,
	}); err != nil {
		return err
	}

	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &userID,
		Action:       string(model.AuditActionChangePassword),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})

	return nil
}

// Logout records a logout audit event
func (s *AuthService) Logout(ctx context.Context, userID uuid.UUID, ip, userAgent string) {
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &userID,
		Action:       string(model.AuditActionLogout),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(200),
	})
}

func intPtr(i int) *int {
	return &i
}

func (r ChangePasswordRequest) normalizedPasswords() (string, string) {
	oldPassword := strings.TrimSpace(r.OldPassword)
	if oldPassword == "" {
		oldPassword = strings.TrimSpace(r.OldPasswordSnake)
	}

	newPassword := strings.TrimSpace(r.NewPassword)
	if newPassword == "" {
		newPassword = strings.TrimSpace(r.NewPasswordSnake)
	}

	return oldPassword, newPassword
}
