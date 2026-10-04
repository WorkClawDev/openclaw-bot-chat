package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/service"
)

type cacheRevisionFixture struct {
	value   string
	changes int
	broken  bool
}

func (s *cacheRevisionFixture) Current(context.Context) (string, error) {
	if s.broken {
		return "", errors.New("offline")
	}
	return s.value, nil
}
func (s *cacheRevisionFixture) Rotate(context.Context) error {
	s.changes++
	s.value = "new"
	return nil
}

type unavailableSessions struct{}

func (unavailableSessions) Put(context.Context, string, []byte, time.Duration) error {
	return errors.New("offline")
}
func (unavailableSessions) Get(context.Context, string) ([]byte, error) {
	return nil, errors.New("offline")
}

func TestBrokerCacheContractAndProtectedRevision(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &cacheRevisionFixture{value: "before"}
	token := strings.Repeat("c", 40)
	s := service.NewBrokerSecurityService(unavailableSessions{}, config.BrokerSecurityConfig{CallbackToken: token}, config.MQTTConfig{Username: "server", ClientID: "server-id", Password: strings.Repeat("p", 40)}, nil, nil)
	h := &BrokerSecurityHandler{Service: s, Revision: &service.BrokerRevision{Store: store}}
	r := gin.New()
	h.Register(r)
	request := func(path, body, secret string) (int, map[string]any) {
		req := httptest.NewRequest("POST", "/internal/broker/"+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Broker-Token", secret)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		var value map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
			t.Fatal(err)
		}
		return w.Code, value
	}
	if code, _ := request("cache-version", `{}`, "wrong"); code != 403 {
		t.Fatal("revision endpoint unprotected")
	}
	if code, body := request("cache-version", `{}`, token); code != 200 || body["cache_revision"] != "before" {
		t.Fatal("missing revision")
	}
	valid := `{"username":"server","clientid":"server-id","action":"subscribe","topic":"chat/#"}`
	if code, body := request("authorization", valid, token); code != 200 || body["result"] != "allow" || body["cache_revision"] != "before" || body["cache_ttl_ms"] != float64(10000) || body["cache_max_age_ms"] != float64(300000) {
		t.Fatal("incorrect bounded cache contract", body)
	}
	if code, body := request("authorization", `{"username":"user","clientid":"u","action":"subscribe","topic":"chat/x"}`, token); code != 503 || body["cache_ttl_ms"] != nil {
		t.Fatal("dependency outage cached as denial")
	}
	store.broken = true
	if code, _ := request("authorization", valid, token); code != 503 {
		t.Fatal("revision outage issued new grant")
	}
	if code, _ := request("cache-version", `{}`, token); code != 503 {
		t.Fatal("revision outage")
	}
}

func TestPermissionMutationsInvalidateOnlyAfterSuccessfulHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &cacheRevisionFixture{value: "before"}
	h := &BrokerSecurityHandler{Revision: &service.BrokerRevision{Store: store}}
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
