#!/usr/bin/env python3
"""Drive the native notification tap test with a simulator-only push injection.

Requires the localhost iOS push fixture and a freshly installed/permission-reset
test app. This does not contact Apple or establish APNs provider acceptance.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--device", required=True)
parser.add_argument("--xctestrun", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--scenario", choices=["settings", "group", "forbidden", "cold", "media", "account"], default="settings")
args = parser.parse_args()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
owned = [d for rows in devices["devices"].values() for d in rows
         if d["udid"] == args.device and d["name"].startswith("ClawChat")]
if not owned:
    raise SystemExit("Use a dedicated ClawChat acceptance simulator")
output = Path(args.output).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
fixture = "http://127.0.0.1:18085"
# Loopback fixture traffic must not inherit macOS/system HTTP proxies.
local_http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with local_http.open(urllib.request.Request(fixture + "/fixture/reset", data=b"{}", method="POST"), timeout=3):
    pass
with local_http.open(fixture + "/api/v1/auth/me", timeout=3) as response:
    user = json.load(response)["data"]["id"]
bot = "00000000-0000-4000-8000-000000000001"
payload = {
    "aps": {"alert": {"title": "V5 notification acceptance", "body": "Open the verified chat"}, "sound": "default"},
    "kind": "chat_message", "user_id": user,
    "conversation_id": f"chat/dm/user/{user}/bot/{bot}",
    "message_id": "00000000-0000-4000-8000-000000000009",
}
cases = {
    "settings": "testNotificationTapOpensAboveSettingsAndReturnsToSettings",
    "group": "testGroupNotificationLoadsGroupAndReturnsToSettings",
    "forbidden": "testRevokedNotificationShowsErrorAboveSettings",
    "cold": "testNotificationColdLaunchRestoresAccountAndOpensChat",
    "media": "testMediaNotificationsLoadImageAudioAndFile",
    "account": "testOldAccountNotificationIsIgnoredAfterSwitchAndCurrentAccountOpens",
}
if args.scenario == "group":
    payload["conversation_id"] = "chat/group/00000000-0000-4000-8000-000000000002"
payload_file = output.with_suffix(".apns")
payload_file.write_text(json.dumps(payload))
with output.with_suffix(".log").open("w") as log:
    process = subprocess.Popen([
        "xcodebuild", "test-without-building", "-xctestrun", args.xctestrun,
        "-destination", f"platform=iOS Simulator,id={args.device}",
        "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
        "-collect-test-diagnostics", "never",
        "-only-testing:clawchatUITests/PushNotificationsV5UITests/" + cases[args.scenario],
        "-resultBundlePath", str(output.with_suffix(".xcresult")),
    ], stdout=log, stderr=subprocess.STDOUT)
    injected = set()
    while process.poll() is None:
        try:
            with local_http.open(fixture + "/fixture/events", timeout=3) as response:
                events = json.load(response)["data"]
            for event in events:
                identity = event.get("id", "legacy")
                if event["type"] != "ready-for-push" or identity in injected:
                    continue
                current = json.loads(json.dumps(payload))
                if event.get("recipient") == "b":
                    current["user_id"] = "00000000-0000-0000-0000-000000000222"
                    current["conversation_id"] = "chat/dm/user/" + current["user_id"] + "/bot/00000000-0000-4000-8000-000000000003"
                if event.get("index"):
                    current["aps"]["alert"]["title"] += " " + event["index"]
                if event.get("media"):
                    current["message_id"] = "00000000-0000-4000-8000-0000000000" + {"image":"10", "audio":"11", "file":"12"}[event["media"]]
                payload_file.write_text(json.dumps(current))
                result = subprocess.run(["xcrun", "simctl", "push", args.device, "site.changer.clawchat", str(payload_file)], capture_output=True, text=True)
                injected.add(identity)
                print("Simulator push injection exit:", result.returncode, "count:", len(injected), flush=True)
                with output.with_suffix(".injection.log").open("a") as injection_log:
                    injection_log.write(result.stdout + result.stderr)
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(1)
    print("Native notification UI test exit:", process.returncode, "injected:", len(injected), flush=True)
    try:
        with local_http.open(fixture + "/fixture/events", timeout=3) as response:
            output.with_suffix(".events.json").write_bytes(response.read())
    except OSError:
        pass
    raise SystemExit(process.returncode)
