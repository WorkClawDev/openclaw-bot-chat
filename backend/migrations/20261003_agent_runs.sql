CREATE TABLE IF NOT EXISTS agent_runs (
 id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id), bot_id UUID NOT NULL REFERENCES bots(id),
 trigger_key TEXT NOT NULL, task_id UUID REFERENCES tasks(id), conversation TEXT, attempt INTEGER NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('queued','running','waiting_input','waiting_approval','paused','succeeded','failed','cancelled')),
 worker_id TEXT, lease_until BIGINT NOT NULL DEFAULT 0, fence BIGINT NOT NULL DEFAULT 0, cancel_requested BOOLEAN NOT NULL DEFAULT false,
 event_seq BIGINT NOT NULL DEFAULT 0, steps INTEGER NOT NULL DEFAULT 0, max_steps INTEGER NOT NULL DEFAULT 80,
 input JSONB, result JSONB, error TEXT, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
 UNIQUE(bot_id,trigger_key)
);
CREATE INDEX IF NOT EXISTS idx_agent_run_task ON agent_runs(task_id);
CREATE TABLE IF NOT EXISTS agent_run_events (
 id UUID PRIMARY KEY, run_id UUID NOT NULL REFERENCES agent_runs(id), seq BIGINT NOT NULL,
 type TEXT NOT NULL, data JSONB, created_at TIMESTAMPTZ NOT NULL, UNIQUE(run_id,seq)
);
