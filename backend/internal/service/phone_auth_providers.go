package service

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
)

var (
	ErrCaptchaInvalid = errors.New("captcha verification failed")
	ErrSMSUnavailable = errors.New("sms provider unavailable")
)

type CaptchaProvider interface {
	Verify(ctx context.Context, token string, ip string) error
}

type SMSProvider interface {
	SendCode(ctx context.Context, countryCode string, phoneNumber string, code string) error
}

func NewCaptchaProvider(cfg config.CaptchaConfig, appMode string) (CaptchaProvider, error) {
	provider := strings.ToLower(strings.TrimSpace(cfg.Provider))
	if provider == "" {
		provider = "mock"
	}
	if appMode == "release" && provider == "mock" {
		return nil, fmt.Errorf("mock captcha provider is not allowed in release mode")
	}
	switch provider {
	case "mock":
		return MockCaptchaProvider{}, nil
	case "turnstile":
		return TurnstileCaptchaProvider{
			secretKey: strings.TrimSpace(cfg.Turnstile.SecretKey),
			endpoint:  defaultString(cfg.Turnstile.Endpoint, "https://challenges.cloudflare.com/turnstile/v0/siteverify"),
			client:    http.DefaultClient,
		}, nil
	case "tencent", "geetest":
		return nil, fmt.Errorf("%s captcha provider is configured but not implemented", provider)
	default:
		return nil, fmt.Errorf("unknown captcha provider %q", provider)
	}
}

func NewSMSProvider(cfg config.SMSConfig, appMode string) (SMSProvider, error) {
	provider := strings.ToLower(strings.TrimSpace(cfg.Provider))
	if provider == "" {
		provider = "mock"
	}
	if appMode == "release" && provider == "mock" {
		return nil, fmt.Errorf("mock sms provider is not allowed in release mode")
	}
	switch provider {
	case "mock":
		return &MockSMSProvider{}, nil
	case "aliyun":
		return AliyunSMSProvider{
			accessKeyID:     strings.TrimSpace(cfg.Aliyun.AccessKeyID),
			accessKeySecret: strings.TrimSpace(cfg.Aliyun.AccessKeySecret),
			signName:        strings.TrimSpace(cfg.Aliyun.SignName),
			templateCode:    strings.TrimSpace(cfg.Aliyun.TemplateCode),
			endpoint:        defaultString(cfg.Aliyun.Endpoint, "https://dysmsapi.aliyuncs.com/"),
			client:          http.DefaultClient,
		}, nil
	default:
		return nil, fmt.Errorf("unknown sms provider %q", provider)
	}
}

type MockCaptchaProvider struct{}

func (MockCaptchaProvider) Verify(ctx context.Context, token string, ip string) error {
	token = strings.TrimSpace(token)
	if token == "" || strings.EqualFold(token, "fail") {
		return ErrCaptchaInvalid
	}
	return nil
}

type TurnstileCaptchaProvider struct {
	secretKey string
	endpoint  string
	client    *http.Client
}

func (p TurnstileCaptchaProvider) Verify(ctx context.Context, token string, ip string) error {
	if p.secretKey == "" {
		return ErrCaptchaInvalid
	}
	form := url.Values{}
	form.Set("secret", p.secretKey)
	form.Set("response", strings.TrimSpace(token))
	if strings.TrimSpace(ip) != "" {
		form.Set("remoteip", ip)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	var parsed struct {
		Success bool `json:"success"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return err
	}
	if !parsed.Success {
		return ErrCaptchaInvalid
	}
	return nil
}

type MockSMSProvider struct {
	LastCode string
}

func (p *MockSMSProvider) SendCode(ctx context.Context, countryCode string, phoneNumber string, code string) error {
	p.LastCode = code
	return nil
}

type AliyunSMSProvider struct {
	accessKeyID     string
	accessKeySecret string
	signName        string
	templateCode    string
	endpoint        string
	client          *http.Client
}

func (p AliyunSMSProvider) SendCode(ctx context.Context, countryCode string, phoneNumber string, code string) error {
	if p.accessKeyID == "" || p.accessKeySecret == "" || p.signName == "" || p.templateCode == "" {
		return ErrSMSUnavailable
	}

	templateParam, _ := json.Marshal(map[string]string{"code": code})
	params := map[string]string{
		"AccessKeyId":      p.accessKeyID,
		"Action":           "SendSms",
		"Format":           "JSON",
		"PhoneNumbers":     phoneNumber,
		"RegionId":         "cn-hangzhou",
		"SignName":         p.signName,
		"SignatureMethod":  "HMAC-SHA1",
		"SignatureNonce":   uuid.NewString(),
		"SignatureVersion": "1.0",
		"TemplateCode":     p.templateCode,
		"TemplateParam":    string(templateParam),
		"Timestamp":        time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"Version":          "2017-05-25",
	}
	params["Signature"] = aliyunSignature("POST", params, p.accessKeySecret)

	form := url.Values{}
	for key, value := range params {
		form.Set(key, value)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	var parsed struct {
		Code    string `json:"Code"`
		Message string `json:"Message"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || !strings.EqualFold(parsed.Code, "OK") {
		if parsed.Message == "" {
			parsed.Message = string(body)
		}
		return fmt.Errorf("%w: aliyun code=%s message=%s", ErrSMSUnavailable, parsed.Code, parsed.Message)
	}
	return nil
}

func aliyunSignature(method string, params map[string]string, secret string) string {
	keys := make([]string, 0, len(params))
	for key := range params {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	pairs := make([]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, aliyunPercentEncode(key)+"="+aliyunPercentEncode(params[key]))
	}
	canonicalized := strings.Join(pairs, "&")
	stringToSign := method + "&" + aliyunPercentEncode("/") + "&" + aliyunPercentEncode(canonicalized)

	mac := hmac.New(sha1.New, []byte(secret+"&"))
	_, _ = mac.Write([]byte(stringToSign))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func aliyunPercentEncode(value string) string {
	escaped := url.QueryEscape(value)
	escaped = strings.ReplaceAll(escaped, "+", "%20")
	escaped = strings.ReplaceAll(escaped, "*", "%2A")
	escaped = strings.ReplaceAll(escaped, "%7E", "~")
	return escaped
}

func defaultString(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
