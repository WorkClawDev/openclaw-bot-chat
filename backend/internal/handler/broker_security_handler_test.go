package handler

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBrokerCallbacksExplicitlyDenyMissingConfiguration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	(&BrokerSecurityHandler{}).Register(r)
	for _, path := range []string{"/internal/broker/authentication", "/internal/broker/authorization"} {
		req := httptest.NewRequest("POST", path, strings.NewReader(`{"username":"forged","clientid":"x"}`))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"result":"deny"`) {
			t.Fatal("callback must explicitly deny, not ignore", w.Code, w.Body.String())
		}
	}
}
