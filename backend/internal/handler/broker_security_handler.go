package handler

import (
	"context"
	"encoding/base64"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"github.com/rs/zerolog/log"
)

type BrokerSecurityHandler struct {
	Service  *service.BrokerSecurityService
	Revision *service.BrokerRevision
}

func (h *BrokerSecurityHandler) Register(router *gin.Engine) {
	router.POST("/internal/broker/authentication", h.Authenticate)
	router.POST("/internal/broker/authorization", h.Authorize)
	router.POST("/internal/broker/cache-version", h.CacheVersion)
}

func (h *BrokerSecurityHandler) CacheVersion(c *gin.Context) {
	if !h.Service.ValidCallback(c.GetHeader("X-Broker-Token")) {
		c.JSON(http.StatusForbidden, gin.H{"result": "deny"})
		return
	}
	if h.Revision != nil {
		if revision, err := h.Revision.Current(c.Request.Context()); err == nil && revision != "" {
			c.JSON(http.StatusOK, gin.H{"cache_revision": revision})
			return
		}
	}
	c.JSON(http.StatusServiceUnavailable, gin.H{"result": "deny"})
}

// Install before registering routes. Only completed permission mutations rotate
// the shared revision; ordinary messages never write this key.
func (h *BrokerSecurityHandler) InvalidatePermissions() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		if h.Revision == nil || c.Writer.Status() < 200 || c.Writer.Status() >= 300 {
			return
		}
		switch c.Request.Method {
		case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		default:
			return
		}
		path := c.FullPath()
		affects := path == "/api/v1/bot-bindings/confirm"
		for _, prefix := range []string{"/api/v1/bots", "/api/v1/groups", "/api/v1/admin/users"} {
			affects = affects || path == prefix || strings.HasPrefix(path, prefix+"/")
		}
		if affects {
			ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
			defer cancel()
			if err := h.Revision.Invalidate(ctx); err != nil {
				log.Warn().Err(err).Msg("broker permission notification failed; bounded leases and refresh remain active")
			}
		}
	}
}

func (h *BrokerSecurityHandler) call(c *gin.Context, auth bool) {
	limit := int64(8192)
	if !auth {
		limit += int64(base64.StdEncoding.EncodedLen(service.MaxBrokerPayloadBytes))
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, limit)
	var req struct {
		Username        string  `json:"username"`
		Password        string  `json:"password"`
		ClientID        string  `json:"clientid"`
		Action          string  `json:"action"`
		Topic           string  `json:"topic"`
		PayloadEncoding string  `json:"payload_encoding"`
		Payload         *string `json:"payload"`
	}
	allowed := false
	var expiry int64
	var revision string
	var policyErr error
	if h.Service.ValidCallback(c.GetHeader("X-Broker-Token")) && c.ShouldBindJSON(&req) == nil {
		if auth {
			allowed, expiry, policyErr = h.Service.AuthenticateDecision(c.Request.Context(), req.Username, req.Password, req.ClientID)
		} else {
			// Capture before the policy read. A concurrent revocation must never
			// label an old decision with a new revision and restore a stale grant.
			if h.Revision != nil {
				revision, policyErr = h.Revision.Current(c.Request.Context())
				if policyErr != nil {
					c.JSON(http.StatusServiceUnavailable, gin.H{"result": "deny"})
					return
				}
			}
			allowed, policyErr = h.Service.AuthorizeDecision(c.Request.Context(), req.Username, req.ClientID, req.Action, req.Topic)
			if allowed && req.Action == "publish" {
				allowed, policyErr = h.Service.AuthorizePublishDecision(c.Request.Context(), req.Username, req.ClientID, req.Topic, req.PayloadEncoding, req.Payload)
			}
		}
	}
	if policyErr != nil {
		// Infrastructure failure is not an authoritative permission revocation.
		c.JSON(http.StatusServiceUnavailable, gin.H{"result": "deny"})
		return
	}
	result := "deny"
	if allowed {
		result = "allow"
	}
	body := gin.H{"result": result, "is_superuser": false}
	if auth && allowed && expiry > 0 {
		body["expire_at"] = expiry
	}
	if !auth && revision != "" {
		body["cache_ttl_ms"] = 10000
		body["cache_max_age_ms"] = 300000
		body["cache_revision"] = revision
	}
	c.JSON(200, body)
}
func (h *BrokerSecurityHandler) Authenticate(c *gin.Context) { h.call(c, true) }
func (h *BrokerSecurityHandler) Authorize(c *gin.Context)    { h.call(c, false) }
