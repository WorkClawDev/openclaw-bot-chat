CREATE TABLE IF NOT EXISTS agent_memories (id uuid PRIMARY KEY,owner_id uuid NOT NULL,bot_id uuid NOT NULL,scope text,content text,source text,confirmed boolean NOT NULL DEFAULT false,created_at timestamptz,updated_at timestamptz);
CREATE INDEX IF NOT EXISTS agent_memories_scope ON agent_memories(owner_id,bot_id,scope);
CREATE TABLE IF NOT EXISTS agent_memory_revisions (bot_id uuid PRIMARY KEY,revision bigint NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS agent_schedules (id uuid PRIMARY KEY,owner_id uuid NOT NULL,bot_id uuid NOT NULL,title text,prompt text,timezone text,recurrence text,missed_policy text,status text,next_at timestamptz,last_task_id uuid,created_at timestamptz,updated_at timestamptz);
CREATE INDEX IF NOT EXISTS agent_schedules_due ON agent_schedules(status,next_at);
CREATE TABLE IF NOT EXISTS agent_schedule_occurrences (id uuid PRIMARY KEY,schedule_id uuid NOT NULL,at timestamptz NOT NULL,task_id uuid,status text,created_at timestamptz,UNIQUE(schedule_id,at));
