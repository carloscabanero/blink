#!/usr/bin/env python3
"""Send Blink's mock Bell payloads using simctl or curl.

For APNs, install the JWT signing dependency first:
  python3 -m pip install 'PyJWT[crypto]>=2,<3'

Fill in the configuration below, then run:
  python3 Bell/push.py ring
  python3 Bell/push.py status
  python3 Bell/push.py ring --via apns
  python3 Bell/push.py ring --direct-target --dry-run

Use real APNs for the NSE. A status hint currently only logs a refresh in Blink.
Simulator and dry-run modes do not need PyJWT or an APNs signing key.
"""

import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid


# Configuration: paste the values from Blink's "CLI push:" logs here.
BELL_ID = "1388F212-0E0E-4086-83F2-84119F61B39E"
BLINK_BUNDLE_ID = "sh.blink.blinkshell"
APNS_DEVICE_TOKEN = "3b3a5d57ed372bb5f695070913a0d3c726e9c62edd2b083dcb7b2d2e96de5b38"
WORK_URL = "blink://terminal/C09D17F7-FFAF-4DBE-AD20-283E0109A012"  # Used only with --direct-target; otherwise keep the Bell fallback.

SIMULATOR = "booted"  # Or a Simulator UUID when several are running.
APNS_HOST = "api.sandbox.push.apple.com"  # Production: api.push.apple.com
# From your Apple Developer account; separate from the Bell SEND token.
APNS_TEAM_ID = "A2H2CL32AG"
APNS_KEY_ID = "6KTFYW8V98"
APNS_KEY_FILE = "AuthKey_6KTFYW8V98.p8"  # Path to AuthKey_<KEY_ID>.p8, e.g. ~/Keys/AuthKey_ABC123DEFG.p8.


def create_apns_token():
    try:
        import jwt
    except ImportError as error:
        raise RuntimeError("Install signing support: python3 -m pip install 'PyJWT[crypto]>=2,<3'") from error

    # One fresh JWT per invocation; curl opens a new APNs connection for each send.
    try:
        return jwt.encode(
            {"iss": APNS_TEAM_ID, "iat": int(time.time())},
            Path(APNS_KEY_FILE).expanduser().read_bytes(),
            algorithm="ES256",
            headers={"kid": APNS_KEY_ID},
        )
    except NotImplementedError as error:
        raise RuntimeError("Install signing support: python3 -m pip install 'PyJWT[crypto]>=2,<3'") from error
    except (OSError, ValueError, TypeError, jwt.PyJWTError) as error:
        raise RuntimeError(f"Cannot sign APNs JWT: {error}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=("ring", "status"))
    parser.add_argument("--via", choices=("simulator", "apns"), default="simulator")
    parser.add_argument("--title", default="CLI Bell", help="Ring title")
    parser.add_argument("--body", default="Sent from Bell/push.py.", help="Ring body")
    parser.add_argument("--state", choices=("idle", "busy", "ok", "warn", "error", "attention"), default="ok", help="Status attached to a Ring")
    parser.add_argument("--progress", type=int, choices=range(101), metavar="0..100", default=100, help="Progress attached to a Ring")
    parser.add_argument("--attention-only", action="store_true", help="Ring without supplied status")
    parser.add_argument("--direct-target", action="store_true", help="Use WORK_URL directly, without needing NSE target rewriting")
    parser.add_argument("--dry-run", action="store_true", help="Print payload and redacted command without sending")
    args = parser.parse_args()

    if not BLINK_BUNDLE_ID.strip():
        parser.error("Set BLINK_BUNDLE_ID in the configuration at the top of this file.")
    try:
        bell_id = str(uuid.UUID(BELL_ID)).upper()
    except ValueError:
        parser.error("Set BELL_ID to the UUID from Blink's log (without the mock-bell. prefix).")
    if args.kind == "status" and (args.attention_only or args.direct_target):
        parser.error("--attention-only and --direct-target apply only to ring.")
    if args.direct_target and not WORK_URL.strip():
        parser.error("Set WORK_URL from Blink's log before using --direct-target.")

    filename = "mock-ring.apns" if args.kind == "ring" else "mock-status-hint.apns"
    payload = json.loads(Path(__file__).with_name(filename).read_text(encoding="utf-8"))
    payload["bell"]["bell_id"] = bell_id
    if args.kind == "ring":
        payload["bell"]["message_id"] = str(uuid.uuid4()).upper()
        payload["aps"]["target-content-id"] = WORK_URL if args.direct_target else f"mock-bell:{bell_id}"
        payload["aps"]["alert"] = {"title": args.title, "body": args.body}
        if args.attention_only:
            payload["bell"].pop("status", None)
        else:
            payload["bell"]["status"] = {
                "title": args.title, "body": args.body,
                "state": args.state, "progress": args.progress,
            }
    body = json.dumps(payload, indent=2)
    if len(body.encode("utf-8")) > 4096:
        parser.error("Payload exceeds APNs' 4096-byte limit.")

    if args.via == "simulator":
        command = ["xcrun", "simctl", "push", SIMULATOR, BLINK_BUNDLE_ID, "-"]
    else:
        if APNS_HOST not in ("api.sandbox.push.apple.com", "api.push.apple.com"):
            parser.error("APNS_HOST must be Apple's sandbox or production APNs host.")
        if not args.dry_run and not all(value.strip() for value in (
            APNS_DEVICE_TOKEN, APNS_TEAM_ID, APNS_KEY_ID, APNS_KEY_FILE
        )):
            parser.error("Set APNS_DEVICE_TOKEN, APNS_TEAM_ID, APNS_KEY_ID, and APNS_KEY_FILE before sending through APNs.")
        if APNS_DEVICE_TOKEN and (
            not re.fullmatch(r"[0-9a-fA-F]+", APNS_DEVICE_TOKEN) or len(APNS_DEVICE_TOKEN) % 2
        ):
            parser.error("APNS_DEVICE_TOKEN must contain hexadecimal bytes, without spaces or brackets.")
        try:
            auth_token = "<redacted>" if args.dry_run else create_apns_token()
        except RuntimeError as error:
            parser.error(str(error))
        push_type, priority = ("alert", "10") if args.kind == "ring" else ("background", "5")
        command = [
            "curl", "--http2", "--silent", "--show-error", "--include", "--fail-with-body",
            "--connect-timeout", "10", "--max-time", "30",
            "--header", f"authorization: bearer {auth_token}",
            "--header", f"apns-topic: {BLINK_BUNDLE_ID}",
            "--header", f"apns-push-type: {push_type}",
            "--header", f"apns-priority: {priority}",
            "--data-binary", "@-",
            f"https://{APNS_HOST}/3/device/{APNS_DEVICE_TOKEN or '<device-token>'}",
        ]

    if args.dry_run:
        redacted = ["authorization: bearer <redacted>" if part.startswith("authorization: bearer ") else part
                    for part in command]
        print("Command (payload supplied on stdin):")
        print(shlex.join(redacted))
        print(body)
        return 0

    print(f"Sending {args.kind} via {args.via} to {BLINK_BUNDLE_ID} (Bell {bell_id})", flush=True)
    try:
        return subprocess.run(command, input=body, text=True).returncode
    except FileNotFoundError:
        parser.error(f"Required command not found: {command[0]}")


if __name__ == "__main__":
    sys.exit(main())
