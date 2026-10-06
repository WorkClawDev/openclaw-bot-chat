package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/storage"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

type publicAssetStorage struct {
	storage.ObjectStorageProvider
	signed int
}

func (s *publicAssetStorage) CreatePresignedDownload(context.Context, string, time.Duration) (string, time.Time, error) {
	s.signed++
	return "https://storage.example.invalid/signed", time.Now().Add(time.Minute), nil
}

func TestPublicRedirectCannotRenewPrivateMessageAttachments(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sql, _ := db.DB()
	t.Cleanup(func() { sql.Close() })
	for _, statement := range []string{
		`CREATE TABLE assets (id TEXT PRIMARY KEY, kind TEXT, status TEXT, owner_user_id TEXT, object_key TEXT, deleted_at DATETIME)`,
		`CREATE TABLE users (id TEXT PRIMARY KEY, status INTEGER, is_deleted BOOLEAN DEFAULT false, avatar_url TEXT, deleted_at DATETIME)`,
		`CREATE TABLE bots (id TEXT PRIMARY KEY, owner_id TEXT, status INTEGER, avatar_url TEXT, deleted_at DATETIME)`,
		`CREATE TABLE groups (id TEXT PRIMARY KEY, owner_id TEXT, is_active BOOLEAN, avatar_url TEXT, deleted_at DATETIME)`,
	} {
		if err := db.Exec(statement).Error; err != nil {
			t.Fatal(err)
		}
	}
	owner, outsider, picture, audio := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	url := "https://chat.example.invalid/api/v1/assets/image/" + picture.String()
	db.Exec("INSERT INTO users(id,status) VALUES(?,1),(?,1)", owner, outsider)
	db.Exec("INSERT INTO assets(id,kind,status,owner_user_id,object_key) VALUES(?,'image','ready',?,'private-image'),(?,'audio','ready',?,'private-audio')", picture, owner, audio, owner)
	provider := &publicAssetStorage{}
	svc := NewAssetService(repository.NewAssetRepository(db), provider, config.StorageConfig{PrivateRead: true, DownloadURLTTL: 60}, config.AssetConfig{})
	ctx := context.Background()
	deny := func() {
		t.Helper()
		if _, err := svc.GetPublicImageURL(ctx, picture.String()); !errors.Is(err, ErrAssetAccessDenied) {
			t.Fatalf("private image redirect: %v", err)
		}
	}
	deny()
	if _, err := svc.GetPublicAudioURL(ctx, audio.String()); !errors.Is(err, ErrAssetAccessDenied) {
		t.Fatalf("private audio redirect: %v", err)
	}
	db.Exec("UPDATE users SET avatar_url = ? WHERE id = ?", url, outsider)
	deny()
	if provider.signed != 0 {
		t.Fatal("unauthorized request reached download signer")
	}
	db.Exec("UPDATE users SET avatar_url = ? WHERE id = ?", url, owner)
	if got, err := svc.GetPublicImageURL(ctx, picture.String()); err != nil || got == "" {
		t.Fatalf("owner's public avatar: %v", err)
	}
	db.Exec("UPDATE users SET avatar_url = NULL WHERE id = ?", owner)
	db.Exec("INSERT INTO bots(id,owner_id,status,avatar_url) VALUES(?,?,1,?)", uuid.New(), outsider, url)
	deny()
	db.Exec("INSERT INTO groups(id,owner_id,is_active,avatar_url) VALUES(?,?,true,?)", uuid.New(), owner, url)
	if _, err := svc.GetPublicImageURL(ctx, picture.String()); err != nil {
		t.Fatal(err)
	}
	db.Exec("UPDATE users SET status = 2 WHERE id = ?", owner)
	deny()
}
