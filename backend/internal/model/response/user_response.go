package response

import (
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

type UserResponse struct {
	ID             uuid.UUID        `json:"id"`
	Username       string           `json:"username"`
	Email          string           `json:"email"`
	Phone          string           `json:"phone,omitempty"`
	Nickname       string           `json:"nickname"`
	Avatar         *string          `json:"avatar,omitempty"`
	AvatarURL      *string          `json:"avatar_url,omitempty"`
	Status         model.UserStatus `json:"status"`
	LastLoginAt    *time.Time       `json:"last_login_at,omitempty"`
	LastLoginIP    *string          `json:"last_login_ip,omitempty"`
	CreatedAt      time.Time        `json:"created_at"`
	CreatedAtAlias time.Time        `json:"createdAt"`
	UpdatedAt      time.Time        `json:"updated_at"`
	UpdatedAtAlias time.Time        `json:"updatedAt"`
}

type AuthUserResponse struct {
	ID             uuid.UUID `json:"id"`
	Username       string    `json:"username"`
	Email          string    `json:"email"`
	Phone          string    `json:"phone,omitempty"`
	Nickname       string    `json:"nickname"`
	Avatar         *string   `json:"avatar,omitempty"`
	AvatarURL      *string   `json:"avatar_url,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	CreatedAtAlias time.Time `json:"createdAt"`
}

type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	TokenType    string `json:"token_type"`
}

type AuthPayloadResponse struct {
	Tokens TokenResponse     `json:"tokens"`
	User   *AuthUserResponse `json:"user,omitempty"`
}

type MeResponse struct {
	ID             uuid.UUID `json:"id"`
	Username       string    `json:"username"`
	Email          string    `json:"email"`
	Phone          string    `json:"phone,omitempty"`
	Nickname       string    `json:"nickname"`
	Avatar         *string   `json:"avatar,omitempty"`
	AvatarURL      *string   `json:"avatar_url,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	CreatedAtAlias time.Time `json:"createdAt"`
}

func NewUserResponse(user *model.User) *UserResponse {
	if user == nil {
		return nil
	}

	return &UserResponse{
		ID:             user.ID,
		Username:       user.Username,
		Email:          userEmail(user),
		Phone:          userPhone(user),
		Nickname:       userNickname(user),
		Avatar:         user.AvatarURL,
		AvatarURL:      user.AvatarURL,
		Status:         user.Status,
		LastLoginAt:    user.LastLoginAt,
		LastLoginIP:    user.LastLoginIP,
		CreatedAt:      user.CreatedAt,
		CreatedAtAlias: user.CreatedAt,
		UpdatedAt:      user.UpdatedAt,
		UpdatedAtAlias: user.UpdatedAt,
	}
}

func NewUserResponses(users []model.User) []UserResponse {
	if len(users) == 0 {
		return []UserResponse{}
	}

	responses := make([]UserResponse, 0, len(users))
	for i := range users {
		responses = append(responses, *NewUserResponse(&users[i]))
	}
	return responses
}

func NewAuthUserResponse(user *model.User) *AuthUserResponse {
	if user == nil {
		return nil
	}

	return &AuthUserResponse{
		ID:             user.ID,
		Username:       user.Username,
		Email:          userEmail(user),
		Phone:          userPhone(user),
		Nickname:       userNickname(user),
		Avatar:         user.AvatarURL,
		AvatarURL:      user.AvatarURL,
		CreatedAt:      user.CreatedAt,
		CreatedAtAlias: user.CreatedAt,
	}
}

func NewMeResponse(user *model.User) *MeResponse {
	if user == nil {
		return nil
	}

	return &MeResponse{
		ID:             user.ID,
		Username:       user.Username,
		Email:          userEmail(user),
		Phone:          userPhone(user),
		Nickname:       userNickname(user),
		Avatar:         user.AvatarURL,
		AvatarURL:      user.AvatarURL,
		CreatedAt:      user.CreatedAt,
		CreatedAtAlias: user.CreatedAt,
	}
}

func userEmail(user *model.User) string {
	if user == nil || user.Email == nil {
		return ""
	}
	return *user.Email
}

func userPhone(user *model.User) string {
	if user == nil || user.PhoneNumber == nil || user.PhoneCountryCode == nil {
		return ""
	}
	return "+" + *user.PhoneCountryCode + *user.PhoneNumber
}

func userNickname(user *model.User) string {
	if user == nil || user.Nickname == nil || *user.Nickname == "" {
		if user == nil {
			return ""
		}
		return user.Username
	}
	return *user.Nickname
}
