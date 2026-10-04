-- Existing accounts remain ordinary users. Bootstrap an administrator explicitly
-- with `go run ./cmd/admin-user -username <existing-account>`.
ALTER TABLE users ADD COLUMN IF NOT EXISTS role varchar(16) NOT NULL DEFAULT 'user';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_role_valid' AND conrelid = 'users'::regclass) THEN
    ALTER TABLE users ADD CONSTRAINT users_role_valid CHECK (role IN ('user', 'admin'));
  END IF;
END $$;
