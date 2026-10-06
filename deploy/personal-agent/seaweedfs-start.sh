#!/bin/sh
set -eu
umask 077
node -e '
const fs = require("node:fs");
const secretKey = fs.readFileSync("/run/secrets/storage-key", "utf8").trim();
if (!secretKey) throw new Error("Storage secret is empty");
fs.writeFileSync("/tmp/seaweedfs-auth.json", JSON.stringify({identities: [{
  name: "personal-agent-storage",
  credentials: [{accessKey: "personal-agent-storage", secretKey}],
  actions: ["Admin", "Read", "Write", "List", "Tagging"],
}]}), {mode: 0o600});
'
exec /opt/seaweedfs/weed -logtostderr=true -v=0 mini \
  -dir=/data -ip=127.0.0.1 -ip.bind=0.0.0.0 -s3.port=9000 \
  -s3.port.iceberg=0 -s3.port.lance=0 -admin.ui=false -webdav=false \
  -s3.config=/tmp/seaweedfs-auth.json -bucket=personal-agent \
  -master.volumeSizeLimitMB=64 -volume.max=4 -master.telemetry.url=
