package handler

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBrokerCallbacksAreNoLongerExposed(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use((&BrokerSecurityHandler{}).InvalidatePermissions())
	for _, path := range []string{"/internal/broker/authentication", "/internal/broker/authorization"} {
		req := httptest.NewRequest("POST", path, strings.NewReader(`{"username":"forged","clientid":"x"}`))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != 404 {
			t.Fatal("legacy callback must not be exposed", w.Code, w.Body.String())
		}
	}
}
