package model

import (
	"database/sql/driver"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// --- User ---

type UserStatus int

const (
	UserStatusInactive UserStatus = 0
	UserStatusActive   UserStatus = 1
	UserStatusBanned   UserStatus = 2
)

type User struct {
	ID           uuid.UUID  `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	Username     string     `gorm:"type:varchar(64);uniqueIndex;not null"`
	Email        string     `gorm:"type:varchar(255);uniqueIndex;not null"`
	PasswordHash string     `gorm:"type:varchar(255);not null"`
	Nickname     *string    `gorm:"type:varchar(128)"`
	AvatarURL    *string    `gorm:"type:varchar(512)"`
	Status       UserStatus `gorm:"type:smallint;not null;default:1"`
	IsDeleted    bool       `gorm:"not null;default:false"`
	LastLoginAt  *time.Time
	LastLoginIP  *string        `gorm:"type:varchar(45)"`
	CreatedAt    time.Time      `gorm:"not null;default:now()"`
	UpdatedAt    time.Time      `gorm:"not null;default:now()"`
	DeletedAt    gorm.DeletedAt `gorm:"index"`
}

func (User) TableName() string { return "users" }

// --- Bot ---

type BotType string

const (
	BotTypeGeneral   BotType = "general"
	BotTypeAssistant BotType = "assistant"
	BotTypeService   BotType = "service"
)

type BotStatus int

const (
	BotStatusDisabled BotStatus = 0
	BotStatusEnabled  BotStatus = 1
)

type Bot struct {
	ID          uuid.UUID      `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	OwnerID     uuid.UUID      `gorm:"type:uuid;not null"`
	Name        string         `gorm:"type:varchar(128);not null"`
	Description *string        `gorm:"type:text"`
	AvatarURL   *string        `gorm:"type:varchar(512)"`
	BotType     BotType        `gorm:"type:varchar(32);not null;default:'general'"`
	Status      BotStatus      `gorm:"type:smallint;not null;default:1"`
	IsPublic    bool           `gorm:"not null;default:false"`
	Config      JSONMap        `gorm:"type:jsonb"`
	MQTTTopic   *string        `gorm:"type:varchar(256)"`
	CreatedAt   time.Time      `gorm:"not null;default:now()"`
	UpdatedAt   time.Time      `gorm:"not null;default:now()"`
	DeletedAt   gorm.DeletedAt `gorm:"index"`
	Owner       *User          `gorm:"foreignKey:OwnerID"`
}

func (Bot) TableName() string { return "bots" }

// --- BotKey ---

type BotKey struct {
	ID         uuid.UUID `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	BotID      uuid.UUID `gorm:"type:uuid;not null"`
	KeyPrefix  string    `gorm:"type:varchar(32);not null"`
	KeyHash    string    `gorm:"type:varchar(255);not null"`
	Name       *string   `gorm:"type:varchar(128)"`
	LastUsedAt *time.Time
	LastUsedIP *string `gorm:"type:varchar(45)"`
	ExpiresAt  *time.Time
	IsActive   bool      `gorm:"not null;default:true"`
	CreatedAt  time.Time `gorm:"not null;default:now()"`
	Bot        *Bot      `gorm:"foreignKey:BotID"`
}

func (BotKey) TableName() string { return "bot_keys" }

// --- Message ---

type SenderType string

const (
	SenderTypeUser   SenderType = "user"
	SenderTypeBot    SenderType = "bot"
	SenderTypeSystem SenderType = "system"
)

type MsgType string

const (
	MsgTypeText  MsgType = "text"
	MsgTypeImage MsgType = "image"
	MsgTypeFile  MsgType = "file"
	MsgTypeAudio MsgType = "audio"
	MsgTypeVideo MsgType = "video"
)

type Message struct {
	ID             int64      `gorm:"primaryKey;autoIncrement"`
	ConversationID string     `gorm:"type:varchar(256);not null;index:idx_messages_conversation_id;uniqueIndex:udx_messages_conversation_seq"`
	MessageID      uuid.UUID  `gorm:"type:uuid;not null;default:uuid_generate_v4()"`
	SenderType     SenderType `gorm:"type:varchar(16);not null"`
	SenderID       *uuid.UUID `gorm:"type:uuid"`
	SenderName     *string    `gorm:"type:varchar(128)"`
	BotID          *uuid.UUID `gorm:"type:uuid;index:idx_messages_bot_id"`
	GroupID        *uuid.UUID `gorm:"type:uuid;index:idx_messages_group_id"`
	MsgType        MsgType    `gorm:"type:varchar(32);not null;default:'text'"`
	Content        string     `gorm:"type:text"`
	Metadata       JSONMap    `gorm:"type:jsonb"`
	MQTTTopic      string     `gorm:"type:varchar(256);not null"`
	QOS            int        `gorm:"type:smallint;not null;default:1"`
	IsRead         bool       `gorm:"not null;default:false"`
	IsDeleted      bool       `gorm:"not null;default:false"`
	Seq            int64      `gorm:"not null;default:0;index:idx_messages_seq;uniqueIndex:udx_messages_conversation_seq"`
	CreatedAt      time.Time  `gorm:"not null;default:now();index:idx_messages_created_at"`
}

func (Message) TableName() string { return "messages" }

// --- Asset ---

type AssetKind string

const (
	AssetKindImage AssetKind = "image"
	AssetKindAudio AssetKind = "audio"
)

type AssetStatus string

const (
	AssetStatusPending AssetStatus = "pending"
	AssetStatusReady   AssetStatus = "ready"
	AssetStatusFailed  AssetStatus = "failed"
)

type Asset struct {
	ID              uuid.UUID      `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	Kind            AssetKind      `gorm:"type:varchar(32);not null"`
	StorageProvider string         `gorm:"type:varchar(32);not null"`
	Bucket          string         `gorm:"type:varchar(255);not null"`
	ObjectKey       string         `gorm:"type:varchar(1024);not null;uniqueIndex"`
	MIMEType        string         `gorm:"type:varchar(255);not null"`
	Size            int64          `gorm:"not null;default:0"`
	FileName        string         `gorm:"type:varchar(512);not null"`
	Width           *int           `gorm:"type:int"`
	Height          *int           `gorm:"type:int"`
	SHA256          *string        `gorm:"type:varchar(128)"`
	Status          AssetStatus    `gorm:"type:varchar(32);not null;default:'pending'"`
	OwnerUserID     *uuid.UUID     `gorm:"type:uuid;index"`
	OwnerBotID      *uuid.UUID     `gorm:"type:uuid;index"`
	SourceURL       *string        `gorm:"type:text"`
	Metadata        JSONMap        `gorm:"type:jsonb"`
	CreatedAt       time.Time      `gorm:"not null;default:now()"`
	UpdatedAt       time.Time      `gorm:"not null;default:now()"`
	DeletedAt       gorm.DeletedAt `gorm:"index"`
}

func (Asset) TableName() string { return "assets" }

// --- Group ---

type Group struct {
	ID          uuid.UUID      `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	Name        string         `gorm:"type:varchar(128);not null"`
	Description *string        `gorm:"type:text"`
	AvatarURL   *string        `gorm:"type:varchar(512)"`
	OwnerID     uuid.UUID      `gorm:"type:uuid;not null"`
	MQTTTopic   *string        `gorm:"type:varchar(256)"`
	IsActive    bool           `gorm:"not null;default:true"`
	MaxMembers  int            `gorm:"not null;default:500"`
	CreatedAt   time.Time      `gorm:"not null;default:now()"`
	UpdatedAt   time.Time      `gorm:"not null;default:now()"`
	DeletedAt   gorm.DeletedAt `gorm:"index"`
	Owner       *User          `gorm:"foreignKey:OwnerID"`
}

func (Group) TableName() string { return "groups" }

// --- GroupMember ---

type GroupMemberRole string

const (
	GroupRoleOwner  GroupMemberRole = "owner"
	GroupRoleAdmin  GroupMemberRole = "admin"
	GroupRoleMember GroupMemberRole = "member"
)

type GroupMember struct {
	ID       uuid.UUID       `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	GroupID  uuid.UUID       `gorm:"type:uuid;not null;uniqueIndex:idx_gm_group_user"`
	UserID   uuid.UUID       `gorm:"type:uuid;not null;uniqueIndex:idx_gm_group_user"`
	Role     GroupMemberRole `gorm:"type:varchar(16);not null;default:'member'"`
	Nickname *string         `gorm:"type:varchar(128)"`
	IsActive bool            `gorm:"not null;default:true"`
	JoinedAt time.Time       `gorm:"not null;default:now()"`
	Group    *Group          `gorm:"foreignKey:GroupID"`
	User     *User           `gorm:"foreignKey:UserID"`
}

func (GroupMember) TableName() string { return "group_members" }

// --- BotGroupMember ---

type BotGroupMember struct {
	ID       uuid.UUID       `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	GroupID  uuid.UUID       `gorm:"type:uuid;not null;uniqueIndex:idx_bgm_group_bot"`
	BotID    uuid.UUID       `gorm:"type:uuid;not null;uniqueIndex:idx_bgm_group_bot"`
	Role     GroupMemberRole `gorm:"type:varchar(16);not null;default:'member'"`
	Nickname *string         `gorm:"type:varchar(128)"`
	IsActive bool            `gorm:"not null;default:true"`
	AddedAt  time.Time       `gorm:"not null;default:now()"`
	Group    *Group          `gorm:"foreignKey:GroupID"`
	Bot      *Bot            `gorm:"foreignKey:BotID"`
}

func (BotGroupMember) TableName() string { return "bot_group_members" }

// --- Task ---

type TaskStatus string

const (
	TaskStatusPending    TaskStatus = "pending"
	TaskStatusAvailable  TaskStatus = "available"
	TaskStatusClaimed    TaskStatus = "claimed"
	TaskStatusInProgress TaskStatus = "in_progress"
	TaskStatusCompleted  TaskStatus = "completed"
	TaskStatusFailed     TaskStatus = "failed"
	TaskStatusBlocked    TaskStatus = "blocked"
)

type TaskPriority string

const (
	TaskPriorityLow      TaskPriority = "low"
	TaskPriorityNormal   TaskPriority = "normal"
	TaskPriorityHigh     TaskPriority = "high"
	TaskPriorityCritical TaskPriority = "critical"
)

type Task struct {
	ID               uuid.UUID    `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	OwnerID          uuid.UUID    `gorm:"type:uuid;not null;index"`
	Title            string       `gorm:"type:varchar(255);not null"`
	Description      *string      `gorm:"type:text"`
	Priority         TaskPriority `gorm:"type:varchar(16);not null;default:'normal';index"`
	Status           TaskStatus   `gorm:"type:varchar(32);not null;default:'pending';index"`
	AssigneeBotID    *uuid.UUID   `gorm:"type:uuid;index"`
	EstimatedStartAt *time.Time
	EstimatedEndAt   *time.Time
	ActualStartAt    *time.Time
	ActualEndAt      *time.Time
	Progress         int            `gorm:"not null;default:0"`
	LatestStatusNote *string        `gorm:"type:text"`
	CreatedAt        time.Time      `gorm:"not null;default:now()"`
	UpdatedAt        time.Time      `gorm:"not null;default:now()"`
	DeletedAt        gorm.DeletedAt `gorm:"index"`
	Owner            *User          `gorm:"foreignKey:OwnerID"`
	AssigneeBot      *Bot           `gorm:"foreignKey:AssigneeBotID"`
	Dependencies     []TaskDependency
	Events           []TaskEvent
}

func (Task) TableName() string { return "tasks" }

type TaskDependency struct {
	ID              uuid.UUID `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	TaskID          uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:idx_task_dependency"`
	DependsOnTaskID uuid.UUID `gorm:"type:uuid;not null;uniqueIndex:idx_task_dependency"`
	CreatedAt       time.Time `gorm:"not null;default:now()"`
	DependsOnTask   *Task     `gorm:"foreignKey:DependsOnTaskID"`
}

func (TaskDependency) TableName() string { return "task_dependencies" }

type TaskEvent struct {
	ID        uuid.UUID  `gorm:"type:uuid;primary_key;default:uuid_generate_v4()"`
	TaskID    uuid.UUID  `gorm:"type:uuid;not null;index"`
	ActorType string     `gorm:"type:varchar(16);not null"`
	ActorID   *uuid.UUID `gorm:"type:uuid"`
	Status    TaskStatus `gorm:"type:varchar(32);not null"`
	Progress  int        `gorm:"not null;default:0"`
	Note      *string    `gorm:"type:text"`
	CreatedAt time.Time  `gorm:"not null;default:now();index"`
}

func (TaskEvent) TableName() string { return "task_events" }

// --- AuditLog ---

type AuditAction string

const (
	AuditActionLogin          AuditAction = "login"
	AuditActionLogout         AuditAction = "logout"
	AuditActionRegister       AuditAction = "register"
	AuditActionUpdateProfile  AuditAction = "update_profile"
	AuditActionChangePassword AuditAction = "change_password"
	AuditActionCreateBot      AuditAction = "create_bot"
	AuditActionUpdateBot      AuditAction = "update_bot"
	AuditActionDeleteBot      AuditAction = "delete_bot"
	AuditActionCreateKey      AuditAction = "create_key"
	AuditActionRevokeKey      AuditAction = "revoke_key"
	AuditActionCreateGroup    AuditAction = "create_group"
	AuditActionUpdateGroup    AuditAction = "update_group"
	AuditActionDeleteGroup    AuditAction = "delete_group"
	AuditActionAddMember      AuditAction = "add_member"
	AuditActionRemoveMember   AuditAction = "remove_member"
	AuditActionSendMessage    AuditAction = "send_message"
)

type AuditLog struct {
	ID            int64      `gorm:"primaryKey;autoIncrement"`
	EventID       uuid.UUID  `gorm:"type:uuid;not null;default:uuid_generate_v4()"`
	UserID        *uuid.UUID `gorm:"type:uuid;index"`
	BotID         *uuid.UUID `gorm:"type:uuid"`
	GroupID       *uuid.UUID `gorm:"type:uuid"`
	Action        string     `gorm:"type:varchar(64);not null;index"`
	ResourceType  *string    `gorm:"type:varchar(64)"`
	ResourceID    *uuid.UUID `gorm:"type:uuid"`
	IPAddress     *string    `gorm:"type:varchar(45)"`
	UserAgent     *string    `gorm:"type:varchar(512)"`
	RequestMethod *string    `gorm:"type:varchar(10)"`
	RequestPath   *string    `gorm:"type:varchar(256)"`
	RequestBody   *string    `gorm:"type:text"`
	ResponseCode  *int
	ErrorMessage  *string   `gorm:"type:text"`
	Metadata      JSONMap   `gorm:"type:jsonb"`
	CreatedAt     time.Time `gorm:"not null;default:now();index"`
}

func (AuditLog) TableName() string { return "audit_logs" }

// --- JSONMap helper ---

type JSONMap map[string]interface{}

func (j *JSONMap) Scan(value interface{}) error {
	if value == nil {
		*j = nil
		return nil
	}
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, j)
}

func (j JSONMap) Value() (driver.Value, error) {
	if j == nil {
		return nil, nil
	}
	return json.Marshal(j)
}
