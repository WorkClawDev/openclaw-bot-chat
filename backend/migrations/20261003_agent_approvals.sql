-- Additive migration; existing clients and task states are unchanged.
CREATE TABLE IF NOT EXISTS agent_approvals (
 id UUID PRIMARY KEY, owner_id UUID NOT NULL REFERENCES users(id), bot_id UUID NOT NULL REFERENCES bots(id),
 run_id TEXT NOT NULL, tool TEXT NOT NULL, parameter_hash TEXT NOT NULL CHECK(length(parameter_hash)=64),
 arguments JSONB, status TEXT NOT NULL CHECK(status IN ('pending','approved','denied')),
 expires_at TIMESTAMPTZ NOT NULL, decided_by UUID REFERENCES users(id), decided_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL,
 UNIQUE(run_id,tool,parameter_hash)
);
CREATE INDEX IF NOT EXISTS idx_agent_approvals_owner ON agent_approvals(owner_id);
