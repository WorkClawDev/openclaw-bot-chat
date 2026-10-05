\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA review_token_version;
SET LOCAL search_path = review_token_version;
CREATE TABLE users (id int PRIMARY KEY, status smallint NOT NULL);
\ir ../20261005_user_token_version.sql
\ir ../20261005_user_token_version.sql
INSERT INTO users(id, status) VALUES (1, 1);
UPDATE users SET status = 2 WHERE id = 1;
DO $$ BEGIN
  IF (SELECT token_version FROM users WHERE id=1) <> 1 THEN RAISE EXCEPTION 'suspension did not revoke'; END IF;
END $$;
UPDATE users SET status = 2 WHERE id = 1;
DO $$ BEGIN
  IF (SELECT token_version FROM users WHERE id=1) <> 1 THEN RAISE EXCEPTION 'unchanged state changed version'; END IF;
END $$;
UPDATE users SET status = 1 WHERE id = 1;
DO $$ BEGIN
  IF (SELECT token_version FROM users WHERE id=1) <> 2 THEN RAISE EXCEPTION 'reactivation did not revoke'; END IF;
END $$;
UPDATE users SET status = 0, token_version = 3 WHERE id = 1;
DO $$ BEGIN
  IF (SELECT token_version FROM users WHERE id=1) <> 3 THEN RAISE EXCEPTION 'application and trigger double increment'; END IF;
END $$;
ROLLBACK;
