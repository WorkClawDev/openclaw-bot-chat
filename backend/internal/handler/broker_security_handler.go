package handler

import (
	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"net/http"
)

type BrokerSecurityHandler struct {
	Service *service.BrokerSecurityService
}

func (h *BrokerSecurityHandler) Register(router *gin.Engine) {
	router.POST("/internal/broker/authentication", h.Authenticate)
	router.POST("/internal/broker/authorization", h.Authorize)
}
func (h *BrokerSecurityHandler) call(c *gin.Context, auth bool) {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 8192)
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		ClientID string `json:"clientid"`
		Action   string `json:"action"`
		Topic    string `json:"topic"`
	}
	allowed := false
	var expiry int64
	if h.Service.ValidCallback(c.GetHeader("X-Broker-Token")) && c.ShouldBindJSON(&req) == nil {
		if auth {
			allowed, expiry = h.Service.Authenticate(c.Request.Context(), req.Username, req.Password, req.ClientID)
		} else {
			allowed = h.Service.Authorize(c.Request.Context(), req.Username, req.ClientID, req.Action, req.Topic)
		}
	}
	result := "deny"
	if allowed {
		result = "allow"
	}
	body := gin.H{"result": result, "is_superuser": false}
	if auth && allowed && expiry > 0 {
		body["expire_at"] = expiry
	}
	c.JSON(200, body)
}
func (h *BrokerSecurityHandler) Authenticate(c *gin.Context) { h.call(c, true) }
func (h *BrokerSecurityHandler) Authorize(c *gin.Context)    { h.call(c, false) }
