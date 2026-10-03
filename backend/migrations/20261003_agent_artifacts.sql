CREATE TABLE IF NOT EXISTS agent_artifacts (
 id uuid PRIMARY KEY, owner_id uuid NOT NULL, bot_id uuid NOT NULL, run_id uuid NOT NULL,
 task_id uuid, asset_id uuid NOT NULL, document_id uuid, file_name text NOT NULL,
 mime_type text, sha256 text NOT NULL, size bigint NOT NULL, version integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(run_id,file_name,sha256)
);
CREATE INDEX IF NOT EXISTS agent_artifacts_owner ON agent_artifacts(owner_id,run_id);
