// Package apns implements the token-authenticated HTTP/2 APNs provider protocol.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type Config struct {
	TeamID, KeyID, Topic string
	PrivateKey           []byte
}
type Client struct {
	config        Config
	key           *ecdsa.PrivateKey
	http          *http.Client
	mu            sync.Mutex
	providerToken string
	tokenTime     time.Time
}

type Notification struct {
	ID, DeviceToken, Environment, UserID, ConversationID, MessageID, Language string
	ExpiresAt                                                                 time.Time
}

type Result struct {
	Accepted      bool
	Retry         bool
	InvalidDevice bool
	InvalidSince  *time.Time
	Reason        string
}

func New(config Config) (*Client, error) {
	if config.TeamID == "" || config.KeyID == "" || config.Topic == "" {
		return nil, errors.New("APNs team, key ID and topic are required")
	}
	key, err := jwt.ParseECPrivateKeyFromPEM(config.PrivateKey)
	if err != nil || key.Curve != elliptic.P256() {
		return nil, errors.New("APNs requires a PEM encoded P-256 private key")
	}
	// Do not retain the PEM once parsed or allow redirects to forward credentials.
	config.PrivateKey = nil
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ForceAttemptHTTP2 = true
	return &Client{config: config, key: key, http: &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func (c *Client) token(now time.Time) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.providerToken != "" && now.Sub(c.tokenTime) < 50*time.Minute && !now.Before(c.tokenTime) {
		return c.providerToken, nil
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": c.config.TeamID, "iat": now.Unix()})
	token.Header["kid"] = c.config.KeyID
	signed, err := token.SignedString(c.key)
	if err == nil {
		c.providerToken, c.tokenTime = signed, now
	}
	return signed, err
}

func (c *Client) Send(ctx context.Context, n Notification) (Result, error) {
	host := "https://api.push.apple.com"
	if n.Environment == "sandbox" {
		host = "https://api.sandbox.push.apple.com"
	} else if n.Environment != "production" {
		return Result{Reason: "InvalidEnvironment"}, nil
	}
	if _, err := hex.DecodeString(n.DeviceToken); err != nil || n.DeviceToken == "" {
		return Result{Reason: "BadDeviceToken", InvalidDevice: true}, nil
	}
	token, err := c.token(time.Now())
	if err != nil {
		return Result{}, errors.New("APNs signing failed")
	}
	body := "You have a new message. Open ClawChat to read it."
	if n.Language == "zh" {
		body = "你收到了一条新消息，打开 ClawChat 查看。"
	}
	thread := sha256.Sum256([]byte(n.ConversationID))
	payload, err := json.Marshal(map[string]any{
		"aps":  map[string]any{"alert": map[string]string{"title": "ClawChat", "body": body}, "sound": "default", "thread-id": hex.EncodeToString(thread[:])},
		"kind": "chat_message", "user_id": n.UserID, "conversation_id": n.ConversationID, "message_id": n.MessageID,
	})
	if err != nil {
		return Result{}, err
	}
	if len(payload) > 4096 {
		return Result{Reason: "PayloadTooLarge"}, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+n.DeviceToken, bytes.NewReader(payload))
	if err != nil {
		return Result{}, errors.New("APNs request failed")
	}
	req.Header.Set("Authorization", "bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("apns-topic", c.config.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-id", n.ID)
	// Stable per delivery so retries can collapse into the same notification.
	// APNs acceptance and a local database commit are not an atomic operation;
	// exactly-once presentation on the device is not guaranteed by this header.
	req.Header.Set("apns-collapse-id", n.ID)
	req.Header.Set("apns-expiration", strconv.FormatInt(n.ExpiresAt.Unix(), 10))
	resp, err := c.http.Do(req)
	if err != nil {
		return Result{}, errors.New("APNs transport unavailable")
	} // URL errors contain device tokens.
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return Result{Accepted: true, Reason: "Accepted"}, nil
	}
	var response struct {
		Reason    string `json:"reason"`
		Timestamp int64  `json:"timestamp"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&response)
	// Only retain known Apple error names; never persist an arbitrary body.
	reason := "ProviderRejected"
	switch response.Reason {
	case "BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken", "ExpiredProviderToken", "InvalidProviderToken", "TooManyProviderTokenUpdates", "TooManyRequests", "ServiceUnavailable", "Shutdown", "InternalServerError", "Forbidden", "PayloadTooLarge", "BadTopic", "MissingTopic":
		reason = response.Reason
	}
	result := Result{Reason: reason, Retry: resp.StatusCode == 429 || resp.StatusCode >= 500 || resp.StatusCode == 403}
	if reason == "Forbidden" {
		result.Retry = false
	}
	if reason == "ExpiredProviderToken" {
		c.mu.Lock()
		c.providerToken = ""
		c.mu.Unlock()
	}
	if reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" || reason == "Unregistered" || reason == "ExpiredToken" {
		result.InvalidDevice, result.Retry = true, false
		if resp.StatusCode == 410 && response.Timestamp > 0 {
			t := time.UnixMilli(response.Timestamp)
			result.InvalidSince = &t
		}
	}
	return result, nil
}
