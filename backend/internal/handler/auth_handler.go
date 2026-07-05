package handler

import (
	"errors"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

// AuthHandler handles authentication endpoints
type AuthHandler struct {
	authService      *service.AuthService
	phoneAuthService *service.PhoneAuthService
}

// NewAuthHandler creates a new auth handler
func NewAuthHandler(authService *service.AuthService, phoneAuthService *service.PhoneAuthService) *AuthHandler {
	return &AuthHandler{authService: authService, phoneAuthService: phoneAuthService}
}

// Register handles user registration
func (h *AuthHandler) Register(c *gin.Context) {
	var req service.RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	tokens, user, err := h.authService.Register(c.Request.Context(), req, ip, userAgent)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrUsernameTaken):
			apiresponse.Conflict(c, "username already taken")
		case errors.Is(err, service.ErrEmailTaken):
			apiresponse.Conflict(c, "email already taken")
		default:
			apiresponse.InternalError(c, "failed to register: "+err.Error())
		}
		return
	}
	c.JSON(201, apiresponse.Response{
		Code:    int(apiresponse.CodeSuccess),
		Message: "registered successfully",
		Data: responsedto.AuthPayloadResponse{
			Tokens: responsedto.TokenResponse{
				AccessToken:  tokens.AccessToken,
				RefreshToken: tokens.RefreshToken,
				ExpiresIn:    tokens.ExpiresIn,
				TokenType:    tokens.TokenType,
			},
			User: responsedto.NewAuthUserResponse(user),
		},
	})
}

func (h *AuthHandler) RequestPhoneCode(c *gin.Context) {
	if h.phoneAuthService == nil {
		apiresponse.NotFound(c, "phone auth is not enabled")
		return
	}

	var req service.PhoneCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	if err := h.phoneAuthService.RequestCode(c.Request.Context(), req, ip, userAgent); err != nil {
		switch {
		case errors.Is(err, service.ErrPhoneAuthDisabled):
			apiresponse.Forbidden(c, "phone auth is disabled")
		case errors.Is(err, service.ErrInvalidPhone):
			apiresponse.BadRequest(c, "invalid phone number")
		case errors.Is(err, service.ErrCaptchaInvalid):
			apiresponse.BadRequest(c, "captcha verification failed")
		case errors.Is(err, service.ErrPhoneRateLimited):
			apiresponse.Error(c, 429, apiresponse.Code(429), "please try again later")
		default:
			apiresponse.InternalError(c, "failed to send verification code")
		}
		return
	}

	apiresponse.SuccessWithMessage(c, "verification code sent", gin.H{
		"cooldown_seconds": h.phoneAuthService.SendCooldownSeconds(),
	})
}

func (h *AuthHandler) PhoneLogin(c *gin.Context) {
	if h.phoneAuthService == nil {
		apiresponse.NotFound(c, "phone auth is not enabled")
		return
	}

	var req service.PhoneLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	tokens, user, created, err := h.phoneAuthService.LoginOrRegister(c.Request.Context(), req, ip, userAgent)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrPhoneAuthDisabled):
			apiresponse.Forbidden(c, "phone auth is disabled")
		case errors.Is(err, service.ErrInvalidPhone):
			apiresponse.BadRequest(c, "invalid phone number")
		case errors.Is(err, service.ErrInvalidPhoneCode):
			apiresponse.Unauthorized(c, "invalid or expired verification code")
		case errors.Is(err, service.ErrUserBanned):
			apiresponse.Forbidden(c, err.Error())
		default:
			apiresponse.InternalError(c, "failed to login")
		}
		return
	}

	statusCode := 200
	message := "login successful"
	if created {
		statusCode = 201
		message = "registered successfully"
	}
	c.JSON(statusCode, apiresponse.Response{
		Code:    int(apiresponse.CodeSuccess),
		Message: message,
		Data: responsedto.AuthPayloadResponse{
			Tokens: responsedto.TokenResponse{
				AccessToken:  tokens.AccessToken,
				RefreshToken: tokens.RefreshToken,
				ExpiresIn:    tokens.ExpiresIn,
				TokenType:    tokens.TokenType,
			},
			User: responsedto.NewAuthUserResponse(user),
		},
	})
}

// Login handles user login
func (h *AuthHandler) Login(c *gin.Context) {
	var req service.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	tokens, user, err := h.authService.Login(c.Request.Context(), req, ip, userAgent)
	if err != nil {
		if errors.Is(err, service.ErrMissingLoginIdentifier) {
			apiresponse.BadRequest(c, "username or email is required")
		} else if errors.Is(err, service.ErrInvalidCredentials) {
			apiresponse.Unauthorized(c, "invalid username or password")
		} else if errors.Is(err, service.ErrUserBanned) {
			apiresponse.Forbidden(c, err.Error())
		} else {
			apiresponse.InternalError(c, "failed to login: "+err.Error())
		}
		return
	}
	c.JSON(200, apiresponse.Response{
		Code:    int(apiresponse.CodeSuccess),
		Message: "login successful",
		Data: responsedto.AuthPayloadResponse{
			Tokens: responsedto.TokenResponse{
				AccessToken:  tokens.AccessToken,
				RefreshToken: tokens.RefreshToken,
				ExpiresIn:    tokens.ExpiresIn,
				TokenType:    tokens.TokenType,
			},
			User: responsedto.NewAuthUserResponse(user),
		},
	})
}

// Refresh handles token refresh
func (h *AuthHandler) Refresh(c *gin.Context) {
	var req service.RefreshRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	tokens, err := h.authService.RefreshToken(c.Request.Context(), req.RefreshToken)
	if err != nil {
		apiresponse.Unauthorized(c, "invalid or expired refresh token")
		return
	}
	c.JSON(200, apiresponse.Response{
		Code:    int(apiresponse.CodeSuccess),
		Message: "token refreshed",
		Data: responsedto.TokenResponse{
			AccessToken:  tokens.AccessToken,
			RefreshToken: tokens.RefreshToken,
			ExpiresIn:    tokens.ExpiresIn,
			TokenType:    tokens.TokenType,
		},
	})
}

// Logout handles user logout
func (h *AuthHandler) Logout(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	h.authService.Logout(c.Request.Context(), userID, ip, userAgent)
	apiresponse.Success(c, gin.H{"message": "logged out"})
}

// Me returns the current user's info
func (h *AuthHandler) Me(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	user, err := h.authService.GetByID(c.Request.Context(), userID)
	if err != nil {
		if errors.Is(err, service.ErrUserNotFound) {
			apiresponse.NotFound(c, "user not found")
			return
		}
		apiresponse.InternalError(c, "failed to load user profile: "+err.Error())
		return
	}

	apiresponse.Success(c, responsedto.NewMeResponse(user))
}

// UpdateMe updates the current user's profile
func (h *AuthHandler) UpdateMe(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	var req service.UpdateProfileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	user, err := h.authService.UpdateProfile(c.Request.Context(), userID, req, ip, userAgent)
	if err != nil {
		if errors.Is(err, service.ErrUserNotFound) {
			apiresponse.NotFound(c, "user not found")
			return
		}
		apiresponse.InternalError(c, "failed to update profile: "+err.Error())
		return
	}

	apiresponse.Success(c, responsedto.NewMeResponse(user))
}

// ChangePassword updates the current user's password
func (h *AuthHandler) ChangePassword(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	var req service.ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	ip := c.ClientIP()
	userAgent := c.GetHeader("User-Agent")
	if err := h.authService.ChangePassword(c.Request.Context(), userID, req, ip, userAgent); err != nil {
		switch {
		case errors.Is(err, service.ErrUserNotFound):
			apiresponse.NotFound(c, "user not found")
		case errors.Is(err, service.ErrIncorrectPassword):
			apiresponse.BadRequest(c, "old password is incorrect")
		case errors.Is(err, service.ErrWeakPassword):
			apiresponse.BadRequest(c, "new password must be at least 8 characters")
		default:
			apiresponse.InternalError(c, "failed to change password: "+err.Error())
		}
		return
	}

	apiresponse.SuccessWithMessage(c, "password changed", nil)
}
