package repository

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func pushFixture(t *testing.T) (*gorm.DB, *PushRepository, model.Message, model.PushDevice) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := db.DB()
	raw.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = raw.Close() })
	for _, sql := range []string{
		`CREATE TABLE users (id text PRIMARY KEY,status integer,is_deleted boolean,deleted_at datetime)`,
		`CREATE TABLE bots (id text PRIMARY KEY,owner_id text,status integer,deleted_at datetime)`,
		`CREATE TABLE groups (id text PRIMARY KEY,owner_id text,is_active boolean,deleted_at datetime)`,
		`CREATE TABLE group_members (group_id text,user_id text,is_active boolean)`,
		`CREATE TABLE bot_group_members (group_id text,bot_id text,is_active boolean)`,
	} {
		if err := db.Exec(sql).Error; err != nil {
			t.Fatal(err)
		}
	}
	if err := db.AutoMigrate(&model.PushDevice{}, &model.PushDelivery{}); err != nil {
		t.Fatal(err)
	}
	user, bot := uuid.New(), uuid.New()
	if err := db.Exec("INSERT INTO users VALUES (?,1,false,NULL)", user).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("INSERT INTO bots VALUES (?,?,1,NULL)", bot, user).Error; err != nil {
		t.Fatal(err)
	}
	repo := NewPushRepository(db)
	device := model.PushDevice{ID: uuid.New(), UserID: user, Token: "abcdef", Environment: "sandbox", Enabled: true, Language: "en"}
	if err := repo.Register(context.Background(), device, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := db.First(&device, "id = ?", device.ID).Error; err != nil {
		t.Fatal(err)
	}
	msg := model.Message{ID: 1, MessageID: uuid.New(), ConversationID: fmt.Sprintf("chat/dm/user/%s/bot/%s", user, bot), SenderType: model.SenderTypeBot, SenderID: &bot, MsgType: model.MsgTypeText, Content: "private content"}
	return db, repo, msg, device
}

func TestPushOutboxRollbackDedupAndEligibility(t *testing.T) {
	db, _, msg, _ := pushFixture(t)
	ctx := context.Background()
	sentinel := errors.New("rollback")
	err := db.Transaction(func(tx *gorm.DB) error {
		if err := EnqueueChatPush(ctx, tx, &msg); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatal(err)
	}
	var count int64
	db.Model(&model.PushDelivery{}).Count(&count)
	if count != 0 {
		t.Fatal("outbox escaped rollback")
	}
	for i := 0; i < 2; i++ {
		if err := EnqueueChatPush(ctx, db, &msg); err != nil {
			t.Fatal(err)
		}
	}
	db.Model(&model.PushDelivery{}).Count(&count)
	if count != 1 {
		t.Fatal("duplicate outbox record")
	}
	for _, kind := range []model.SenderType{model.SenderTypeUser, model.SenderTypeSystem} {
		msg.ID++
		msg.SenderType = kind
		if err := EnqueueChatPush(ctx, db, &msg); err != nil {
			t.Fatal(err)
		}
	}
	msg.ID++
	msg.SenderType = model.SenderTypeBot
	msg.ConversationID = fmt.Sprintf("chat/dm/bot/%s/bot/%s", msg.SenderID, uuid.New())
	if err := EnqueueChatPush(ctx, db, &msg); err != nil {
		t.Fatal(err)
	}
	db.Model(&model.PushDelivery{}).Count(&count)
	if count != 1 {
		t.Fatal("nonrecipient message generated notification")
	}
}

func TestPushDeviceRotationRevocationAndAccountSwitch(t *testing.T) {
	db, repo, _, device := pushFixture(t)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := repo.Register(ctx, device, now); err != nil {
		t.Fatal(err)
	}
	var current model.PushDevice
	db.First(&current, "id = ?", device.ID)
	if current.Revision != device.Revision {
		t.Fatal("heartbeat invalidated queued deliveries")
	}
	if err := repo.Disable(ctx, uuid.New(), device.ID, now); err != nil {
		t.Fatal(err)
	}
	db.First(&current, "id = ?", device.ID)
	if !current.Enabled {
		t.Fatal("other account disabled device")
	}
	device.UserID = uuid.New()
	if err := repo.Register(ctx, device, now); err != nil {
		t.Fatal(err)
	}
	db.First(&current, "id = ?", device.ID)
	if current.Revision == device.Revision || current.UserID != device.UserID {
		t.Fatal("account transfer failed")
	}
	old := current
	current.Token = "aabbcc"
	if err := repo.Register(ctx, current, now); err != nil {
		t.Fatal(err)
	}
	if err := repo.Invalidate(ctx, &old, nil); err != nil {
		t.Fatal(err)
	}
	db.First(&current, "id = ?", device.ID)
	if !current.Enabled || current.Token != "aabbcc" {
		t.Fatal("stale APNs response disabled rotated token")
	}
	oldTimestamp := now.Add(-time.Minute)
	if err := repo.Invalidate(ctx, &current, &oldTimestamp); err != nil {
		t.Fatal(err)
	}
	db.First(&current, "id = ?", device.ID)
	if !current.Enabled {
		t.Fatal("old APNs invalidation disabled newer registration")
	}
	if err := repo.Disable(ctx, current.UserID, current.ID, now); err != nil {
		t.Fatal(err)
	}
	db.First(&current, "id = ?", device.ID)
	if current.Enabled {
		t.Fatal("disable did not persist")
	}
	current.ID = uuid.New()
	current.Enabled = true
	if err := repo.Register(ctx, current, now); err != nil {
		t.Fatal(err)
	}
	var count int64
	db.Model(&model.PushDevice{}).Count(&count)
	if count != 1 {
		t.Fatal("reinstall duplicated the token")
	}
}

func TestPushGroupRecipientsAndLeaseFencing(t *testing.T) {
	db, repo, msg, device := pushFixture(t)
	ctx := context.Background()
	group, member, outsider := uuid.New(), uuid.New(), uuid.New()
	for _, id := range []uuid.UUID{member, outsider} {
		if err := db.Exec("INSERT INTO users VALUES (?,1,false,NULL)", id).Error; err != nil {
			t.Fatal(err)
		}
	}
	db.Exec("INSERT INTO groups VALUES (?,?,true,NULL)", group, device.UserID)
	db.Exec("INSERT INTO group_members VALUES (?,?,true)", group, device.UserID)
	db.Exec("INSERT INTO group_members VALUES (?,?,true)", group, member)
	db.Exec("INSERT INTO group_members VALUES (?,?,false)", group, outsider)
	db.Exec("INSERT INTO bot_group_members VALUES (?,?,true)", group, *msg.SenderID)
	msg.ConversationID = "chat/group/" + group.String()
	ids, err := repo.EligibleRecipients(ctx, &msg)
	if err != nil || len(ids) != 2 {
		t.Fatal("incorrect current group recipients", ids, err)
	}
	if err := EnqueueChatPush(ctx, db, &msg); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	one, err := repo.Claim(ctx, now)
	if err != nil || one == nil {
		t.Fatal(err)
	}
	if another, err := repo.Claim(ctx, now); err != nil || another != nil {
		t.Fatal("concurrent lease claimed", err)
	}
	two, err := repo.Claim(ctx, now.Add(61*time.Second))
	if err != nil || two == nil || two.LeaseID == one.LeaseID {
		t.Fatal("lease not reclaimed", err)
	}
	if err := repo.Finish(ctx, one, "accepted", "Accepted", now); err != nil {
		t.Fatal(err)
	}
	var stored model.PushDelivery
	db.First(&stored, "id = ?", one.ID)
	if stored.State != "pending" {
		t.Fatal("stale worker overwrote active lease")
	}
	if err := repo.Finish(ctx, two, "accepted", "Accepted", now); err != nil {
		t.Fatal(err)
	}
	db.First(&stored, "id = ?", one.ID)
	if stored.State != "accepted" {
		t.Fatal("current worker could not finish")
	}
	db.Exec("UPDATE bot_group_members SET is_active=false")
	ids, err = repo.EligibleRecipients(ctx, &msg)
	if err != nil || len(ids) != 0 {
		t.Fatal("removed bot still sends notifications")
	}
}

func TestPushDeviceValidation(t *testing.T) {
	_, repo, _, device := pushFixture(t)
	for _, modify := range []func(*model.PushDevice){func(d *model.PushDevice) { d.Token = "not hex" }, func(d *model.PushDevice) { d.Token = "abc" }, func(d *model.PushDevice) { d.Environment = "unknown" }, func(d *model.PushDevice) { d.UserID = uuid.Nil }, func(d *model.PushDevice) { d.Language = "invalid" }} {
		bad := device
		modify(&bad)
		if !errors.Is(repo.Register(context.Background(), bad, time.Now()), ErrInvalidPushDevice) {
			t.Fatal("invalid registration accepted")
		}
	}
}
