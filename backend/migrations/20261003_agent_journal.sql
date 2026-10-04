CREATE TABLE IF NOT EXISTS agent_inboxes (
 id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id), bot_id UUID NOT NULL REFERENCES bots(id),
 message_id TEXT NOT NULL, message JSONB NOT NULL, status TEXT NOT NULL, response JSONB, delivered BOOLEAN NOT NULL DEFAULT false,
 created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL, UNIQUE(bot_id,message_id)
);
CREATE INDEX IF NOT EXISTS idx_agent_inbox_pending ON agent_inboxes(bot_id,status,delivered);
CREATE TABLE IF NOT EXISTS agent_contexts (
 id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id), bot_id UUID NOT NULL REFERENCES bots(id),
 scope TEXT NOT NULL, data JSONB, updated_at TIMESTAMPTZ NOT NULL, UNIQUE(bot_id,scope)
);
CREATE TABLE IF NOT EXISTS agent_tool_calls (
 id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id), bot_id UUID NOT NULL REFERENCES bots(id),
 run_id TEXT NOT NULL, key TEXT NOT NULL, tool TEXT NOT NULL, idempotent BOOLEAN NOT NULL,
 status TEXT NOT NULL, result JSONB, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL, UNIQUE(bot_id,run_id,key)
);
