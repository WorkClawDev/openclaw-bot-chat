package handler

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/config"
)

func TestPhonePresentationExposesOnlyPublicConfiguration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewAuthHandler(nil, nil)
	h.ConfigurePhonePresentation(true, config.CaptchaConfig{Provider: "turnstile", Turnstile: config.TurnstileCaptchaConfig{SiteKey: "public-widget", SecretKey: "private-verifier", Endpoint: "https://private.invalid"}}, "release")
	r := gin.New()
	r.GET("/config", h.PhoneConfiguration)
	r.GET("/challenge", h.PhoneChallenge)
	for _, path := range []string{"/config", "/challenge"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 200 {
			t.Fatalf("%s: status %d", path, w.Code)
		}
		if strings.Contains(w.Body.String(), "private-verifier") || strings.Contains(w.Body.String(), "private.invalid") {
			t.Fatal("private configuration leaked")
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("auth configuration must not be cached")
		}
		if path == "/challenge" {
			for _, marker := range []string{"public-widget", "phoneCaptcha", "data-expired-callback", "data-timeout-callback", "https://challenges.cloudflare.com/turnstile/v0/api.js"} {
				if !strings.Contains(w.Body.String(), marker) {
					t.Fatalf("missing challenge integration %q", marker)
				}
			}
			if !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
				t.Fatal("missing frame restriction")
			}
		}
	}
}

func TestUnavailablePhonePresentationNeverOffersChallenge(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, test := range []struct {
		name, provider, siteKey, mode string
		enabled, wantEnabled          bool
	}{
		{"disabled", "turnstile", "public", "release", false, false},
		{"missing public key", "turnstile", "", "release", true, false},
		{"unknown provider", "other", "public", "debug", true, false},
		{"release mock", "mock", "", "release", true, false},
		{"local mock", "mock", "", "debug", true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := NewAuthHandler(nil, nil)
			h.ConfigurePhonePresentation(test.enabled, config.CaptchaConfig{Provider: test.provider, Turnstile: config.TurnstileCaptchaConfig{SiteKey: test.siteKey}}, test.mode)
			r := gin.New()
			r.GET("/config", h.PhoneConfiguration)
			r.GET("/challenge", h.PhoneChallenge)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest("GET", "/config", nil))
			var got struct {
				Data struct {
					Enabled bool `json:"enabled"`
				} `json:"data"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got.Data.Enabled != test.wantEnabled {
				t.Fatalf("enabled=%v", got.Data.Enabled)
			}
			w = httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest("GET", "/challenge", nil))
			if w.Code != 404 {
				t.Fatalf("unavailable challenge status=%d", w.Code)
			}
		})
	}
}

func TestPhoneChallengeEscapesPublicKey(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewAuthHandler(nil, nil)
	h.ConfigurePhonePresentation(true, config.CaptchaConfig{Provider: "turnstile", Turnstile: config.TurnstileCaptchaConfig{SiteKey: `"><script>alert(1)</script>`}}, "debug")
	r := gin.New()
	r.GET("/challenge", h.PhoneChallenge)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/challenge", nil))
	if strings.Contains(w.Body.String(), "<script>alert(1)</script>") {
		t.Fatal("unescaped widget configuration")
	}
}
