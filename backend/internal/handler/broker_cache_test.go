package handler

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

type permissionPublisher struct{ changes int }

func (p *permissionPublisher) NotifyPermissionsChanged() { p.changes++ }
func TestPermissionMutationsInvalidateOnlyAfterSuccessfulHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &permissionPublisher{}
	h := &BrokerSecurityHandler{Service: store}
	r := gin.New()
	r.Use(h.InvalidatePermissions())
	for _, row := range []struct {
		method, path string
		status       int
		invalidates  bool
	}{
		{"PUT", "/api/v1/admin/users/u/access", 200, true},
		{"DELETE", "/api/v1/groups/g/members/u", 200, true},
		{"DELETE", "/api/v1/bots/b/keys/k", 200, true},
		{"POST", "/api/v1/bot-bindings/confirm", 200, true},
		{"POST", "/api/v1/messages/chat", 200, false},
		{"GET", "/api/v1/groups/g", 200, false},
		{"PUT", "/api/v1/bots/denied", 403, false},
	} {
		status, before := row.status, store.changes
		r.Handle(row.method, row.path, func(c *gin.Context) {
			if store.changes != before {
				t.Fatal("invalidated before committed mutation")
			}
			c.Status(status)
		})
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(row.method, row.path, nil))
		if (store.changes > before) != row.invalidates {
			t.Fatal("wrong invalidation", row)
		}
	}
}
