-- Phone-code auth support for domestic iOS login/registration.

ALTER TABLE users
    ALTER COLUMN email DROP NOT NULL,
    ALTER COLUMN password_hash DROP NOT NULL;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS phone_country_code VARCHAR(8),
    ADD COLUMN IF NOT EXISTS phone_number VARCHAR(32),
    ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS auth_provider VARCHAR(32) NOT NULL DEFAULT 'password';

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone
    ON users(phone_country_code, phone_number)
    WHERE phone_country_code IS NOT NULL
      AND phone_number IS NOT NULL
      AND deleted_at IS NULL;
