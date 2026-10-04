package handler

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"strings"
)

// Permission mutations schedule a bounded, coalesced control-plane update.
// This handler does not expose broker authentication callbacks.
type BrokerPolicyPublisher interface{ NotifyPermissionsChanged() }
type BrokerSecurityHandler struct{ Service BrokerPolicyPublisher }

func (h *BrokerSecurityHandler) InvalidatePermissions() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		if h.Service == nil || c.Writer.Status() < 200 || c.Writer.Status() >= 300 {
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
			h.Service.NotifyPermissionsChanged()
		}
	}
}
