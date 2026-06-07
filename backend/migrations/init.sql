-- OpenClaw Bot Chat Database Schema
-- PostgreSQL 15+

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- Table: users
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    username        VARCHAR(64) NOT NULL UNIQUE,
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   VARCHAR(255) NOT NULL,
    nickname        VARCHAR(128),
    avatar_url      VARCHAR(512),
    status          SMALLINT    NOT NULL DEFAULT 0,  -- 0: inactive, 1: active, 2: banned
    is_deleted      BOOLEAN     NOT NULL DEFAULT false,
    last_login_at   TIMESTAMPTZ,
    last_login_ip   VARCHAR(45),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_status ON users(status);

-- ============================================================
-- Table: bots
-- ============================================================
CREATE TABLE IF NOT EXISTS bots (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id        UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            VARCHAR(128) NOT NULL,
    description     TEXT,
    avatar_url      VARCHAR(512),
    bot_type        VARCHAR(32)  NOT NULL DEFAULT 'general',  -- general, assistant, service
    status          SMALLINT    NOT NULL DEFAULT 1,  -- 0: disabled, 1: enabled
    is_public       BOOLEAN     NOT NULL DEFAULT false,
    config          JSONB,  -- flexible configuration
    mqtt_topic      VARCHAR(256),  -- auto-generated or custom MQTT topic
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX idx_bots_owner_id ON bots(owner_id);
CREATE INDEX idx_bots_status ON bots(status);
CREATE INDEX idx_bots_mqtt_topic ON bots(mqtt_topic);

-- ============================================================
-- Table: bot_keys
-- ============================================================
CREATE TABLE IF NOT EXISTS bot_keys (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    bot_id          UUID        NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    key_prefix      VARCHAR(32) NOT NULL,  -- first 12 chars for identification
    key_hash        VARCHAR(255) NOT NULL, -- bcrypt hash of full key
    name            VARCHAR(128),
    last_used_at    TIMESTAMPTZ,
    last_used_ip    VARCHAR(45),
    expires_at      TIMESTAMPTZ,
    is_active       BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bot_keys_bot_id ON bot_keys(bot_id);
CREATE INDEX idx_bot_keys_prefix ON bot_keys(key_prefix);
CREATE INDEX idx_bot_keys_active ON bot_keys(is_active);

-- ============================================================
-- Table: messages
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
    id              BIGSERIAL   PRIMARY KEY,
    conversation_id VARCHAR(256) NOT NULL,  -- e.g. "user/{uid}/bot/{bid}" or "group/{gid}"
    message_id      UUID        NOT NULL DEFAULT uuid_generate_v4(),
    sender_type     VARCHAR(16)  NOT NULL,  -- 'user', 'bot', 'system'
    sender_id       UUID,
    sender_name     VARCHAR(128),
    bot_id          UUID,  -- target bot
    group_id        UUID,  -- if group message
    msg_type        VARCHAR(32)  NOT NULL DEFAULT 'text',  -- text, image, file, audio, video
    content         TEXT,
    metadata        JSONB,  -- extra data like attachments, reply-to, etc.
    mqtt_topic      VARCHAR(256) NOT NULL,
    qos             SMALLINT    NOT NULL DEFAULT 1,
    is_read         BOOLEAN     NOT NULL DEFAULT false,
    is_deleted      BOOLEAN     NOT NULL DEFAULT false,
    seq             BIGINT      NOT NULL DEFAULT 0,  -- for pagination
    CONSTRAINT uq_messages_conversation_seq UNIQUE (conversation_id, seq),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX idx_messages_bot_id ON messages(bot_id);
CREATE INDEX idx_messages_group_id ON messages(group_id);
CREATE INDEX idx_messages_sender ON messages(sender_type, sender_id);
CREATE INDEX idx_messages_created_at ON messages(created_at);
CREATE INDEX idx_messages_seq ON messages(conversation_id, seq DESC);

-- ============================================================
-- Table: assets
-- ============================================================
CREATE TABLE IF NOT EXISTS assets (
    id               UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    kind             VARCHAR(32)  NOT NULL,
    storage_provider VARCHAR(32)  NOT NULL,
    bucket           VARCHAR(255) NOT NULL,
    object_key       VARCHAR(1024) NOT NULL UNIQUE,
    mime_type        VARCHAR(255) NOT NULL,
    size             BIGINT       NOT NULL DEFAULT 0,
    file_name        VARCHAR(512) NOT NULL,
    width            INTEGER,
    height           INTEGER,
    sha256           VARCHAR(128),
    status           VARCHAR(32)  NOT NULL DEFAULT 'pending',
    owner_user_id    UUID,
    owner_bot_id     UUID,
    source_url       TEXT,
    metadata         JSONB,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ
);

CREATE INDEX idx_assets_owner_user_id ON assets(owner_user_id);
CREATE INDEX idx_assets_owner_bot_id ON assets(owner_bot_id);
CREATE INDEX idx_assets_status ON assets(status);

-- ============================================================
-- Table: groups
-- ============================================================
CREATE TABLE IF NOT EXISTS groups (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(128) NOT NULL,
    description     TEXT,
    avatar_url      VARCHAR(512),
    owner_id        UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mqtt_topic      VARCHAR(256),
    is_active       BOOLEAN     NOT NULL DEFAULT true,
    max_members     INT         NOT NULL DEFAULT 500,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX idx_groups_owner_id ON groups(owner_id);
CREATE INDEX idx_groups_mqtt_topic ON groups(mqtt_topic);

-- ============================================================
-- Table: group_members
-- ============================================================
CREATE TABLE IF NOT EXISTS group_members (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role        VARCHAR(16)  NOT NULL DEFAULT 'member',  -- owner, admin, member
    nickname    VARCHAR(128),  -- custom nickname in group
    is_active   BOOLEAN     NOT NULL DEFAULT true,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(group_id, user_id)
);

CREATE INDEX idx_group_members_group_id ON group_members(group_id);
CREATE INDEX idx_group_members_user_id ON group_members(user_id);

-- ============================================================
-- Table: bot_group_members ( bots in groups )
-- ============================================================
CREATE TABLE IF NOT EXISTS bot_group_members (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    bot_id      UUID        NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    role        VARCHAR(16)  NOT NULL DEFAULT 'member',
    nickname    VARCHAR(128),
    is_active   BOOLEAN     NOT NULL DEFAULT true,
    added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(group_id, bot_id)
);

CREATE INDEX idx_bot_group_members_group_id ON bot_group_members(group_id);
CREATE INDEX idx_bot_group_members_bot_id ON bot_group_members(bot_id);

-- ============================================================
-- Tables: tasks, task_dependencies, task_events
-- ============================================================
CREATE TABLE IF NOT EXISTS tasks (
    id                  UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id            UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title               VARCHAR(255) NOT NULL,
    description         TEXT,
    priority            VARCHAR(16)  NOT NULL DEFAULT 'normal',
    status              VARCHAR(32)  NOT NULL DEFAULT 'pending',
    parent_task_id      UUID         REFERENCES tasks(id) ON DELETE SET NULL,
    assignee_bot_id     UUID         REFERENCES bots(id) ON DELETE SET NULL,
    estimated_start_at  TIMESTAMPTZ,
    estimated_end_at    TIMESTAMPTZ,
    actual_start_at     TIMESTAMPTZ,
    actual_end_at       TIMESTAMPTZ,
    progress            INTEGER      NOT NULL DEFAULT 0,
    latest_status_note  TEXT,
    result              JSONB,
    error               JSONB,
    dispatched_at       TIMESTAMPTZ,
    claimed_at          TIMESTAMPTZ,
    reviewed_at         TIMESTAMPTZ,
    reviewed_by         UUID         REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ
);

CREATE INDEX idx_tasks_owner_id ON tasks(owner_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_priority ON tasks(priority);
CREATE INDEX idx_tasks_parent_task_id ON tasks(parent_task_id);
CREATE INDEX idx_tasks_assignee_bot_id ON tasks(assignee_bot_id);

CREATE TABLE IF NOT EXISTS task_dependencies (
    id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    task_id             UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    depends_on_task_id  UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(task_id, depends_on_task_id)
);

CREATE INDEX idx_task_dependencies_task_id ON task_dependencies(task_id);
CREATE INDEX idx_task_dependencies_depends_on_task_id ON task_dependencies(depends_on_task_id);

CREATE TABLE IF NOT EXISTS task_events (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    task_id     UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    actor_type  VARCHAR(16) NOT NULL,
    actor_id    UUID,
    event_type  VARCHAR(64) NOT NULL DEFAULT 'status_changed',
    status      VARCHAR(32) NOT NULL,
    progress    INTEGER     NOT NULL DEFAULT 0,
    note        TEXT,
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_task_events_task_id ON task_events(task_id);
CREATE INDEX idx_task_events_event_type ON task_events(event_type);
CREATE INDEX idx_task_events_created_at ON task_events(created_at);

-- ============================================================
-- Table: audit_logs
-- ============================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    id              BIGSERIAL   PRIMARY KEY,
    event_id        UUID        NOT NULL DEFAULT uuid_generate_v4(),
    user_id         UUID,
    bot_id          UUID,
    group_id        UUID,
    action          VARCHAR(64) NOT NULL,  -- login, create_bot, delete_key, etc.
    resource_type   VARCHAR(64),
    resource_id     UUID,
    ip_address      VARCHAR(45),
    user_agent      VARCHAR(512),
    request_method  VARCHAR(10),
    request_path    VARCHAR(256),
    request_body    TEXT,
    response_code   INTEGER,
    error_message   TEXT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX idx_audit_logs_action ON audit_logs(action);
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at);

-- ============================================================
-- Trigger to auto-update updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_bots_updated_at BEFORE UPDATE ON bots
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_assets_updated_at BEFORE UPDATE ON assets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_groups_updated_at BEFORE UPDATE ON groups
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tasks_updated_at BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
