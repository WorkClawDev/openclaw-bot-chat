#!/bin/sh
set -eu
# Values come from mounted Docker secrets. Never echo them or enable shell tracing.
for binding in ${PERSONAL_AGENT_SECRET_BINDINGS:-}; do
  name=${binding%%:*}; file=${binding#*:}
  case "$name" in DATABASE_PASSWORD|JWT_SECRET|MQTT_PASSWORD|BROKER_SECURITY_CALLBACK_TOKEN|STORAGE_S3_SECRET_KEY|BOT_CHAT_BOT_KEY|OPENAI_COMPAT_API_KEY) ;; *) exit 64;; esac
  test -r "/run/secrets/$file"
  value=$(cat "/run/secrets/$file")
  test -n "$value"
  export "$name=$value"
done
exec "$@"
