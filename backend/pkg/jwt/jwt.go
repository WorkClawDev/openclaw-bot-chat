package jwt

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

var (
	ErrInvalidToken = errors.New("invalid token")
	ErrExpiredToken = errors.New("token has expired")
)

// Claims represents JWT claims
type Claims struct {
	TokenVersion int64     `json:"token_version,omitempty"`
	UserID       uuid.UUID `json:"user_id"`
	Username     string    `json:"username"`
	TokenType    string    `json:"token_type"` // "access" or "refresh"
	jwt.RegisteredClaims
}

// Manager handles JWT operations
type Manager struct {
	secret          []byte
	accessTokenTTL  time.Duration
	refreshTokenTTL time.Duration
	issuer          string
}

// Config holds JWT manager configuration
type Config struct {
	Secret          string
	AccessTokenTTL  int // seconds
	RefreshTokenTTL int // seconds
	Issuer          string
}

// NewManager creates a new JWT manager
func NewManager(cfg Config) *Manager {
	return &Manager{
		secret:          []byte(cfg.Secret),
		accessTokenTTL:  time.Duration(cfg.AccessTokenTTL) * time.Second,
		refreshTokenTTL: time.Duration(cfg.RefreshTokenTTL) * time.Second,
		issuer:          cfg.Issuer,
	}
}

// GenerateAccessToken generates a new access token
func (m *Manager) GenerateAccessToken(userID uuid.UUID, username string, tokenVersion int64) (string, error) {
	now := time.Now()
	claims := Claims{
		TokenVersion: tokenVersion,
		UserID:       userID,
		Username:     username,
		TokenType:    "access",
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    m.issuer,
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(m.accessTokenTTL)),
			NotBefore: jwt.NewNumericDate(now),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(m.secret)
}

// GenerateRefreshToken generates a new refresh token
func (m *Manager) GenerateRefreshToken(userID uuid.UUID, username string, tokenVersion int64) (string, error) {
	now := time.Now()
	claims := Claims{
		TokenVersion: tokenVersion,
		UserID:       userID,
		Username:     username,
		TokenType:    "refresh",
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    m.issuer,
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(m.refreshTokenTTL)),
			NotBefore: jwt.NewNumericDate(now),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(m.secret)
}

// GenerateTokenPair generates both access and refresh tokens
func (m *Manager) GenerateTokenPair(userID uuid.UUID, username string, tokenVersion int64) (accessToken, refreshToken string, err error) {
	accessToken, err = m.GenerateAccessToken(userID, username, tokenVersion)
	if err != nil {
		return "", "", err
	}
	refreshToken, err = m.GenerateRefreshToken(userID, username, tokenVersion)
	if err != nil {
		return "", "", err
	}
	return accessToken, refreshToken, nil
}

// ValidateToken validates a token and returns its claims
func (m *Manager) ValidateToken(tokenString string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return m.secret, nil
	})
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, ErrInvalidToken
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

// ValidateAccessToken validates an access token
func (m *Manager) ValidateAccessToken(tokenString string) (*Claims, error) {
	claims, err := m.ValidateToken(tokenString)
	if err != nil {
		return nil, err
	}
	if claims.TokenType != "access" {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

// ValidateRefreshToken validates a refresh token
func (m *Manager) ValidateRefreshToken(tokenString string) (*Claims, error) {
	claims, err := m.ValidateToken(tokenString)
	if err != nil {
		return nil, err
	}
	if claims.TokenType != "refresh" {
		return nil, ErrInvalidToken
	}
	return claims, nil
}
