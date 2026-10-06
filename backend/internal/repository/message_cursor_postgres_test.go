package repository

import (
	"context"
	"errors"
	"os"
	"regexp"
	"testing"
	"time"

	"github.com/google/uuid"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestConversationCursorPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("set TEST_POSTGRES_DSN to an isolated *_test or *_acceptance database")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sql, _ := db.DB()
	defer sql.Close()
	var database string
	if err := db.Raw("SELECT current_database()").Scan(&database).Error; err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`_(test|acceptance)$`).MatchString(database) {
		t.Fatal("refusing a non-test database")
	}
	rollback := errors.New("successful rollback-only cursor test")
	err = db.Transaction(func(tx *gorm.DB) error {
		schema := "review_cursor_" + uuid.NewString()[:8]
		if err := tx.Exec("CREATE SCHEMA " + schema).Error; err != nil {
			return err
		}
		if err := tx.Exec("SET LOCAL search_path TO " + schema).Error; err != nil {
			return err
		}
		for _, ddl := range []string{
			"CREATE TABLE messages (conversation_id text, sender_id uuid, bot_id uuid, is_deleted boolean DEFAULT false, created_at timestamptz)",
			"CREATE TABLE bots (id uuid, owner_id uuid)",
		} {
			if err := tx.Exec(ddl).Error; err != nil {
				return err
			}
		}
		user := uuid.New()
		now := time.Now().UTC()
		for _, row := range []struct {
			id string
			at time.Time
		}{{"a", now}, {"b", now}, {"c", now.Add(-time.Microsecond)}} {
			if err := tx.Exec("INSERT INTO messages(conversation_id,sender_id,created_at) VALUES(?,?,?)", row.id, user, row.at).Error; err != nil {
				return err
			}
		}
		repo := NewMessageRepository(tx)
		var cursor *ConversationCandidate
		for _, want := range []string{"a", "b", "c"} {
			rows, err := repo.GetConversationCandidates(context.Background(), user, nil, 1, cursor)
			if err != nil {
				return err
			}
			if len(rows) != 1 || rows[0].ConversationID != want {
				return errors.New("cursor lost precision or tie ordering")
			}
			cursor = &rows[0]
		}
		rows, err := repo.GetConversationCandidates(context.Background(), user, nil, 1, cursor)
		if err != nil {
			return err
		}
		if len(rows) != 0 {
			return errors.New("cursor repeated a row")
		}
		return rollback
	})
	if !errors.Is(err, rollback) {
		t.Fatal(err)
	}
}
