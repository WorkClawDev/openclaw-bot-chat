ALTER TABLE tasks
    ADD COLUMN IF NOT EXISTS result JSONB,
    ADD COLUMN IF NOT EXISTS error JSONB,
    ADD COLUMN IF NOT EXISTS parent_task_id UUID REFERENCES tasks(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS dispatched_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE task_events
    ADD COLUMN IF NOT EXISTS event_type VARCHAR(64) NOT NULL DEFAULT 'status_changed',
    ADD COLUMN IF NOT EXISTS payload JSONB;

CREATE INDEX IF NOT EXISTS idx_task_events_event_type ON task_events(event_type);
CREATE INDEX IF NOT EXISTS idx_tasks_parent_task_id ON tasks(parent_task_id);
