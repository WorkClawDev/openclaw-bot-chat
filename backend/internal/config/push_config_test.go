package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPushConfigDefaultsAndEnvironment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte("app:\n  mode: test\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{"PUSH_ENABLED": "false", "PUSH_TEAM_ID": "", "PUSH_KEY_ID": "", "PUSH_TOPIC": "", "PUSH_PRIVATE_KEY_PATH": ""} {
		t.Setenv(key, value)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Push.Enabled {
		t.Fatal("unconfigured push enabled")
	}
	for key, value := range map[string]string{"PUSH_ENABLED": "true", "PUSH_TEAM_ID": "TESTTEAM", "PUSH_KEY_ID": "TESTKEY", "PUSH_TOPIC": "site.changer.clawchat", "PUSH_PRIVATE_KEY_PATH": "/run/secrets/test-apns.p8"} {
		t.Setenv(key, value)
	}
	cfg, err = Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Push.Enabled || cfg.Push.TeamID != "TESTTEAM" || cfg.Push.KeyID != "TESTKEY" || cfg.Push.Topic != "site.changer.clawchat" || cfg.Push.PrivateKeyPath != "/run/secrets/test-apns.p8" {
		t.Fatal("push environment configuration ignored")
	}
}
