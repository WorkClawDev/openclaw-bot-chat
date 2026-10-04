#!/bin/sh
set -eu
# Keep the configured egress proxy, while routing this deployment's own HTTP
# services directly. Go's S3 client honors these variables as well.
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,postgres,redis,mqtts,emqx,minio,backend,host.docker.internal"
export no_proxy="$NO_PROXY"
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
