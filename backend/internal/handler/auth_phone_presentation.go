package handler

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"html/template"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/config"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

// Only public presentation data is retained here. Provider secrets never reach the client.
type phoneAuthPresentation struct {
	enabled  bool
	provider string
	siteKey  string
}

func (h *AuthHandler) ConfigurePhonePresentation(enabled bool, cfg config.CaptchaConfig, mode string) {
	provider := strings.ToLower(strings.TrimSpace(cfg.Provider))
	if provider == "" {
		provider = "mock"
	}
	ready := enabled && ((provider == "mock" && mode != "release") || (provider == "turnstile" && strings.TrimSpace(cfg.Turnstile.SiteKey) != ""))
	h.phonePresentation = phoneAuthPresentation{ready, provider, strings.TrimSpace(cfg.Turnstile.SiteKey)}
}

func (h *AuthHandler) PhoneConfiguration(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	apiresponse.Success(c, gin.H{"enabled": h.phonePresentation.enabled, "captcha_provider": h.phonePresentation.provider})
}

func (h *AuthHandler) PhoneChallenge(c *gin.Context) {
	p := h.phonePresentation
	if !p.enabled || p.provider != "turnstile" {
		apiresponse.NotFound(c, "phone verification is unavailable")
		return
	}
	var random [24]byte
	if _, err := rand.Read(random[:]); err != nil {
		apiresponse.InternalError(c, "could not start verification")
		return
	}
	nonce := base64.RawStdEncoding.EncodeToString(random[:])
	var body bytes.Buffer
	if err := phoneChallengeTemplate.Execute(&body, struct{ SiteKey, Nonce string }{p.siteKey, nonce}); err != nil {
		apiresponse.InternalError(c, "could not start verification")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Header("Referrer-Policy", "no-referrer")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"' https://challenges.cloudflare.com; style-src 'nonce-"+nonce+"'; frame-src https://challenges.cloudflare.com; connect-src https://challenges.cloudflare.com; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	c.Data(http.StatusOK, "text/html; charset=utf-8", body.Bytes())
}

var phoneChallengeTemplate = template.Must(template.New("phone-verification").Parse(`<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><meta charset="utf-8">
<title>ClawChat verification</title>
<style nonce="{{.Nonce}}">body{font:16px system-ui;margin:24px;color:#202124;background:#fff}main{display:flex;flex-direction:column;align-items:center;gap:20px;margin-top:32px}p{line-height:1.5;text-align:center}</style>
<script nonce="{{.Nonce}}">
function report(event,token){window.webkit?.messageHandlers?.phoneCaptcha?.postMessage({event:event,token:token||""});}
function verified(token){report("verified",token);}
function failed(){report("error");return true;}
function expired(){report("expired");}
function timedOut(){report("timeout");}
</script>
<script nonce="{{.Nonce}}" src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
</head><body><main><p>请完成安全验证<br>Complete the security check</p>
<div class="cf-turnstile" data-sitekey="{{.SiteKey}}" data-action="phone_code" data-callback="verified" data-error-callback="failed" data-expired-callback="expired" data-timeout-callback="timedOut" data-retry="never"></div>
</main></body></html>`))
