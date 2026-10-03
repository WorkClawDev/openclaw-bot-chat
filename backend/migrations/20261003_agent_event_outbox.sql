ALTER TABLE agent_run_events ADD COLUMN IF NOT EXISTS published boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS agent_run_event_unpublished ON agent_run_events(created_at) WHERE published = false;
