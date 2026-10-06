package response

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/openclaw-bot-chat/backend/internal/model"
)

func TestSelfResponsesReportPasswordCapabilityWithoutHash(t *testing.T) {
	empty, hash := "", "private-password-hash"
	for _, test := range []struct {
		name string
		hash *string
		want bool
	}{{"phone-only", nil, false}, {"empty hash", &empty, false}, {"password configured", &hash, true}} {
		t.Run(test.name, func(t *testing.T) {
			user := &model.User{PasswordHash: test.hash, Role: model.UserRoleAdmin}
			for _, value := range []any{NewAuthUserResponse(user), NewMeResponse(user)} {
				encoded, err := json.Marshal(value)
				if err != nil {
					t.Fatal(err)
				}
				var fields map[string]any
				if err := json.Unmarshal(encoded, &fields); err != nil {
					t.Fatal(err)
				}
				if fields["role"] != string(model.UserRoleAdmin) {
					t.Fatal("master account role lost in self response")
				}
				if got, present := fields["has_password"]; !present || got != test.want {
					t.Fatalf("password capability=%v present=%v", got, present)
				}
				if strings.Contains(string(encoded), hash) || strings.Contains(string(encoded), "password_hash") {
					t.Fatal("hash leaked")
				}
			}
			public, err := json.Marshal(NewUserResponse(user))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(public), "has_password") {
				t.Fatal("credential capability exposed outside self responses")
			}
		})
	}
	if NewAuthUserResponse(nil) != nil || NewMeResponse(nil) != nil {
		t.Fatal("nil user must remain nil")
	}
}
