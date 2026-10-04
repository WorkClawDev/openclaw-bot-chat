#!/bin/sh
set -eu
token=$(cat /run/secrets/broker-token)
case "$token" in *[!a-zA-Z0-9_-]*|'') echo 'Invalid broker token format' >&2; exit 64;; esac
sed "s/__BROKER_CALLBACK_TOKEN__/$token/g" /opt/emqx/etc/personal-agent.conf.template > /opt/emqx/etc/emqx.conf
export EMQX_NODE__COOKIE="$(cat /run/secrets/node-cookie)"
export EMQX_DASHBOARD__DEFAULT_USERNAME=personal-agent-admin
export EMQX_DASHBOARD__DEFAULT_PASSWORD="$(cat /run/secrets/dashboard-key)"
exec /opt/emqx/bin/emqx foreground
