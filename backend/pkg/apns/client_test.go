package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func testClient(t *testing.T) *Client {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	c, err := New(Config{TeamID: "TESTTEAM", KeyID: "TESTKEY", Topic: "site.changer.clawchat", PrivateKey: pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAPNsRequestSignatureHeadersAndPrivacy(t *testing.T) {
	c := testClient(t)
	var previousToken string
	c.http.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.sandbox.push.apple.com" || r.URL.Path != "/3/device/abcdef01" || r.Method != "POST" {
			t.Errorf("wrong destination")
		}
		for key, want := range map[string]string{"apns-topic": "site.changer.clawchat", "apns-push-type": "alert", "apns-priority": "10", "apns-id": "delivery", "apns-collapse-id": "delivery", "apns-expiration": "2000"} {
			if r.Header.Get(key) != want {
				t.Errorf("incorrect %s", key)
			}
		}
		encoded := strings.TrimPrefix(r.Header.Get("Authorization"), "bearer ")
		token, err := jwt.Parse(encoded, func(token *jwt.Token) (any, error) {
			if token.Method != jwt.SigningMethodES256 || token.Header["kid"] != "TESTKEY" {
				t.Error("invalid signing headers")
			}
			return &c.key.PublicKey, nil
		}, jwt.WithValidMethods([]string{"ES256"}), jwt.WithIssuer("TESTTEAM"))
		if err != nil || !token.Valid {
			t.Error("invalid signature")
		}
		if previousToken != "" && encoded != previousToken {
			t.Error("provider JWT not reused")
		}
		previousToken = encoded
		data, _ := io.ReadAll(r.Body)
		var payload map[string]any
		if err := json.Unmarshal(data, &payload); err != nil {
			t.Fatal(err)
		}
		if len(data) > 4096 || payload["user_id"] != "recipient" || payload["conversation_id"] != "conversation" || payload["message_id"] != "message" {
			t.Errorf("routing payload invalid")
		}
		aps := payload["aps"].(map[string]any)
		if aps["badge"] != nil || aps["alert"].(map[string]any)["body"] != "你收到了一条新消息，打开 ClawChat 查看。" {
			t.Error("generic alert invalid")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(""))}, nil
	})
	for i := 0; i < 2; i++ {
		result, err := c.Send(context.Background(), Notification{ID: "delivery", DeviceToken: "abcdef01", Environment: "sandbox", UserID: "recipient", ConversationID: "conversation", MessageID: "message", Language: "zh", ExpiresAt: time.Unix(2000, 0)})
		if err != nil || !result.Accepted {
			t.Fatal("not accepted", err)
		}
	}
}

func TestAPNsResponsesAndTokenInvalidation(t *testing.T) {
	for _, tc := range []struct {
		code           int
		reason         string
		retry, invalid bool
	}{
		{410, "Unregistered", false, true}, {410, "ExpiredToken", false, true}, {400, "BadDeviceToken", false, true},
		{400, "DeviceTokenNotForTopic", false, true}, {403, "ExpiredProviderToken", true, false},
		{403, "Forbidden", false, false}, {429, "TooManyRequests", true, false}, {500, "InternalServerError", true, false}, {400, "PayloadTooLarge", false, false},
	} {
		t.Run(tc.reason, func(t *testing.T) {
			c := testClient(t)
			c.http.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "api.push.apple.com" {
					t.Error("wrong production host")
				}
				data, _ := json.Marshal(map[string]any{"reason": tc.reason, "timestamp": 123456000})
				return &http.Response{StatusCode: tc.code, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
			})
			result, err := c.Send(context.Background(), Notification{DeviceToken: "ab", Environment: "production"})
			if err != nil || result.Accepted || result.Retry != tc.retry || result.InvalidDevice != tc.invalid {
				t.Fatalf("incorrect classification: %+v %v", result, err)
			}
			if tc.code == 410 && (result.InvalidSince == nil || result.InvalidSince.UnixMilli() != 123456000) {
				t.Error("missing invalidation timestamp")
			}
			if tc.reason == "ExpiredProviderToken" && c.providerToken != "" {
				t.Error("expired provider JWT not discarded")
			}
		})
	}
}

func TestAPNsUsesHTTP2AndNeverLeaksTokenInError(t *testing.T) {
	c := testClient(t)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("provider request must use HTTP/2")
		}
		w.WriteHeader(200)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	transport := server.Client().Transport
	c.http.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		replacement, _ := http.NewRequestWithContext(r.Context(), r.Method, server.URL+r.URL.Path, r.Body)
		replacement.Header = r.Header
		return transport.RoundTrip(replacement)
	})
	if result, err := c.Send(context.Background(), Notification{DeviceToken: "ab", Environment: "sandbox"}); err != nil || !result.Accepted {
		t.Fatal(result, err)
	}
	c.http.Transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("transport with secret-device-token")
	})
	_, err := c.Send(context.Background(), Notification{DeviceToken: "abcdef", Environment: "sandbox"})
	if err == nil || strings.Contains(err.Error(), "abcdef") || strings.Contains(err.Error(), "secret-device-token") {
		t.Fatal("sensitive transport error was exposed")
	}
}

func TestAPNsRejectsInvalidKeyAndRefreshesOldJWT(t *testing.T) {
	if _, err := New(Config{TeamID: "t", KeyID: "k", Topic: "a", PrivateKey: []byte("invalid")}); err == nil {
		t.Fatal("accepted invalid key")
	}
	c := testClient(t)
	now := time.Now()
	first, err := c.token(now.Add(-51 * time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.token(now)
	if err != nil || first == second {
		t.Fatal("old JWT not renewed")
	}
}
