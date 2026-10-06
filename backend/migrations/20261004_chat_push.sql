-- Optional APNs delivery. This schema is also installed by startup AutoMigrate.
-- Device tokens are routing credentials: exclude them from logs and exports.
CREATE TABLE IF NOT EXISTS push_devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    token varchar(1024) NOT NULL,
    environment varchar(16) NOT NULL,
    revision uuid NOT NULL,
    language varchar(8) NOT NULL,
    enabled boolean NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_push_token_environment ON push_devices(token, environment);
CREATE INDEX IF NOT EXISTS idx_push_devices_user_id ON push_devices(user_id);
CREATE INDEX IF NOT EXISTS idx_push_devices_expires_at ON push_devices(expires_at);
CREATE TABLE IF NOT EXISTS push_deliveries (
    id uuid PRIMARY KEY,
    message_row_id bigint NOT NULL,
    device_id uuid NOT NULL,
    user_id uuid NOT NULL,
    device_revision uuid NOT NULL,
    state varchar(16) NOT NULL,
    attempts integer NOT NULL,
    next_attempt_at timestamptz NOT NULL,
    lease_id uuid,
    lease_until timestamptz,
    last_reason varchar(64) NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_push_message_device ON push_deliveries(message_row_id, device_id);
CREATE INDEX IF NOT EXISTS idx_push_due ON push_deliveries(state, next_attempt_at);
