#!/bin/sh
set -eu
umask 077
token=$(cat /run/secrets/broker-token)
case "$token" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid broker token format' >&2; exit 64;; esac
sed "s/__BROKER_CALLBACK_TOKEN__/$token/g" /opt/emqx/etc/personal-agent.conf.template > /opt/emqx/etc/emqx.conf
backend_password=$(cat /run/secrets/backend-password)
case "$backend_password" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid backend password format' >&2; exit 64;; esac
# The persistence client connects before the callback HTTP server starts.
# Only this private identity bypasses the HTTP authentication dependency.
printf 'user_id,password,is_superuser\npersonal-agent-backend,%s,false\n' "$backend_password" > /opt/emqx/etc/personal-agent-auth.csv
printf '%s\n' '{allow, {username, "personal-agent-backend"}, all, ["chat/#", "agent/user/+/events"]}.' > /opt/emqx/etc/personal-agent-acl.conf
export EMQX_NODE__COOKIE="$(cat /run/secrets/node-cookie)"
export EMQX_DASHBOARD__DEFAULT_USERNAME=personal-agent-admin
export EMQX_DASHBOARD__DEFAULT_PASSWORD="$(cat /run/secrets/dashboard-key)"
exec /opt/emqx/bin/emqx foreground
