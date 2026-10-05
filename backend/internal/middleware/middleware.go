package middleware

import (
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"github.com/openclaw-bot-chat/backend/pkg/response"
	"github.com/rs/zerolog"
)

// Logger returns a zerolog middleware
func Logger(log zerolog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		log.Debug().
			Str("method", c.Request.Method).
			Str("path", c.Request.URL.Path).
			Str("ip", c.ClientIP()).
			Msg("request started")
		c.Next()
		log.Debug().
			Str("method", c.Request.Method).
			Str("path", c.Request.URL.Path).
			Int("status", c.Writer.Status()).
			Msg("request completed")
	}
}

// CORS returns a CORS middleware
func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Origin, Content-Type, Accept, Authorization, X-API-Key, X-Bot-Key")
		c.Header("Access-Control-Expose-Headers", "Content-Length, Content-Type")
		c.Header("Access-Control-Max-Age", "86400")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	}
}

// JWTAuth returns a JWT authentication middleware
func JWTAuth(jwtManager *jwt.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" {
			response.Unauthorized(c, "missing authorization header")
			c.Abort()
			return
		}
		parts := strings.SplitN(authHeader, " ", 2)
		if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
			response.Unauthorized(c, "invalid authorization header format")
			c.Abort()
			return
		}
		tokenString := parts[1]
		claims, err := jwtManager.ValidateAccessToken(tokenString)
		if err != nil {
			if err == jwt.ErrExpiredToken {
				response.Unauthorized(c, "token has expired")
			} else {
				response.Unauthorized(c, "invalid token")
			}
			c.Abort()
			return
		}
		// Store user info in context
		c.Set("userID", claims.UserID)
		c.Set("username", claims.Username)
		c.Set("tokenVersion", claims.TokenVersion)
		c.Next()
	}
}

// GetUserID extracts user ID from gin context
func GetUserID(c *gin.Context) (uuid.UUID, bool) {
	val, exists := c.Get("userID")
	if !exists {
		return uuid.UUID{}, false
	}
	userID, ok := val.(uuid.UUID)
	return userID, ok
}

// GetUsername extracts username from gin context
func GetUsername(c *gin.Context) (string, bool) {
	val, exists := c.Get("username")
	if !exists {
		return "", false
	}
	username, ok := val.(string)
	return username, ok
}

// RateLimiter is a simple token-bucket rate limiter (placeholder)
// In production, use Redis-based rate limiting
func RateLimiter() gin.HandlerFunc {
	return func(c *gin.Context) {
		// TODO: Implement Redis-based rate limiting
		c.Next()
	}
}

// Recovery returns a panic recovery middleware with logging
func Recovery(log zerolog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if r := recover(); r != nil {
				log.Error().Interface("panic", r).Msg("panic recovered")
				response.InternalError(c, "internal server error")
				c.Abort()
			}
		}()
		c.Next()
	}
}
