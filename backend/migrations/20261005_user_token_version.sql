-- Missing version claims represent version zero. Status changes permanently
-- revoke both access and refresh JWTs without retaining every issued token.
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version BIGINT NOT NULL DEFAULT 0;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_token_version_valid' AND conrelid = 'users'::regclass) THEN
    ALTER TABLE users ADD CONSTRAINT users_token_version_valid CHECK (token_version >= 0);
  END IF;
END $$;
-- Cover status changes by maintenance SQL and older application instances too.
CREATE OR REPLACE FUNCTION advance_user_token_version() RETURNS trigger AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.token_version <= OLD.token_version THEN
    NEW.token_version := OLD.token_version + 1;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS users_status_revoke_tokens ON users;
CREATE TRIGGER users_status_revoke_tokens BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION advance_user_token_version();
