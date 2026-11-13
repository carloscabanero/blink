# Carlos: testing the Relay v8 client

Target: `carloscabanero/blink:bell-client-v8`, with PR #3 applied. These instructions describe the PR implementation, not the older mock-only checkpoints in the integration diary.

## 1. Check out the actual PR

Use a separate checkout to preserve your existing work:

```bash
git clone --branch bell-client-v8 --recurse-submodules https://github.com/carloscabanero/blink.git blink-bell-test
cd blink-bell-test
git fetch origin pull/3/head:pr-3-testing
git switch pr-3-testing
```

The guide and `Tools/BellSender/main.go` are included in the PR checkout. The original implementation head, before this testing handoff, was `106f69bc2106ebd965095a3f2dda354f77b144d9`.

## 2. Run deterministic tests first (Mac, no phone or Relay)

```bash
bash Tools/BellWireTests/run.sh
bash Tools/BellTransportTests/run.sh
```

Expected at the original PR head: 10 codec checks and 23 transport/config/recovery/Ask checks. These exercise encrypted wire compatibility, signatures, retry identity, durable offline operations, state ordering and verdict recovery through fixtures. They do **not** prove StoreKit, APNs or physical-device delivery.

## 3. Build and sign on your Mac

Use full Xcode, not Command Line Tools (`xcode-select -p`). Initialize dependencies:

```bash
./get_frameworks.sh
./get_resources.sh
```

If you have no `developer_setup.xcconfig`, copy `template_setup.xcconfig` to it; otherwise preserve your existing file. Use your normal signing setup. Open `Blink.xcodeproj`, resolve Swift packages, choose the Blink scheme and a physical iPhone. Keep Push Notifications, the Notification Service Extension (NSE), App Groups and their shared entitlements enabled. The app and NSE must use compatible signing and shared-group settings. Do not follow the generic README suggestion to disable push for this test.

Production currently supports the `com.blink.shell` and `sh.blink.blinkshell` app topics. The signed bundle/team must match one of the provisioned server configurations. An arbitrary personal bundle/team will need its own server/APNs configuration; changing only the bundle ID locally is insufficient. Do not send Apple private keys in a PR.

Xcode Scheme → Run → Arguments Passed On Launch:

```text
-BellRelayURL https://bell.blink.sh
-BellAPNsEnvironment sandbox
```

Use `sandbox` for a development-signed build. TestFlight/App Store builds use `production` APNs (even though TestFlight StoreKit purchases are sandbox transactions). The APNs environment and StoreKit environment are separate. Debug defaults to sandbox; Release defaults to production; saved explicit overrides win.

Remove `BELL_PAID_TOKEN` from the scheme environment when testing production. There is no development-purchase bypass on production. Launch once unlocked so notification actions register; allow notifications in iOS Settings.

## 4. Prove paid enrollment — this is still an open production gate

The signed-in Apple account needs a real, locally verified current entitlement for one of:

- `blink_plus_1y_2999`
- `blink_shell_plus_1y_1999`
- `blink_build_basic_1m_799`
- `blink_plus_build_1m_999`

The classic/unlimited zero-price unlock alone does not qualify. Use the app's normal purchase/restore flow if needed; this test does not require a new purchase when an eligible entitlement already exists. A local Xcode StoreKit configuration is not proof that the production server will accept an Apple-signed transaction. Turn it off for the real enrollment test.

In a test Terminal, open Quick Actions → Bell → Create Bell, then Receive → Loud. Save the copied `token.content_secret` privately. Creation is asynchronous: the token dialog alone does not mean the server accepted enrollment, creation or binding. Confirm successful enrollment/bind via device diagnostics and an actual delivered Ring below. Server logs, if needed, require the operator; you do not need production SSH access to run the client test.

Explicit URL/environment settings persist. An old private sandbox journal cannot silently migrate to production: use a separate test installation/container for another Relay origin. Do not delete your normal app data to work around the origin guard.

## 5. Send an encrypted Ring and a confirm Ask

The PR has no finished `ring` CLI. `bellctl` is a fake owner/device utility, not a substitute for the iPhone's owner identity. The supplied Go sender uses only the copied SEND/READ capability; it never needs the app journal, MANAGE key or APNs key.

Get the Bell's public ID locally: set an Xcode breakpoint in `TermController.showBellToken`, then evaluate `po self.bell?.id`. Remove UUID hyphens to obtain 32 hex characters. Resume the app. This ID is required as authenticated encryption input, not as a credential.

Clone the server's protocol module separately (Go version as specified in its `go.mod`):

```bash
git clone https://github.com/blinksh/bell.git bell-relay
cd bell-relay
git checkout af99b09
go build -o /tmp/bell-test-sender /absolute/path/to/blink-bell-test/Tools/BellSender/main.go
```

On your Mac, read the copied capability without putting it in shell history (bash):

```bash
read -r -s -p 'Paste copied Bell token: ' BLINK_BELL
export BLINK_BELL
printf '\n'
/tmp/bell-test-sender -bell-id YOUR_32_HEX_BELL_ID
```

Expected: HTTP202 plus an encrypted notification reading **Carlos Bell test**. Acceptance is not delivery proof. Tap it and confirm it returns to the original Terminal without executing a command.

Then:

```bash
/tmp/bell-test-sender -bell-id YOUR_32_HEX_BELL_ID -ask
# Copy the printed Ask ID, not your token:
/tmp/bell-test-sender -lookup ASK_ID
```

Long-press/expand the notification, unlock if required, select Approve. Lookup must show `approve` with **Verified sender verdict MAC: approve**. Repeat with a fresh Ask and Deny. Actions must not open a Terminal or execute commands. Send a fresh Ask with `-ttl 30`, wait past expiry, and confirm no accepted late verdict. Only confirm Approve/Deny is supported; arbitrary choice Asks are not.

Finish with `unset BLINK_BELL`. Never paste the capability, journal, raw APNs token or private logs into a public issue.

## 6. Physical-device acceptance matrix

Use new message/Ask IDs on each send (the helper generates them). Record actual results, build/signing environment and timestamps.

| Scenario | Expected result |
| --- | --- |
| Foreground, then background/locked, then ordinary process restart | Correct decrypted Ring and original Terminal routing; no duplicate Bell/binding after restart. iOS force-quit has different delivery restrictions and is not a guaranteed background-execution case. |
| Two Terminals / Spaces with distinct Bells | Each notification routes to its own original target; opening does not replay commands. |
| Receive → Silent | Send with `-loud=false -progress 42`: state reconciles on foreground refresh, without a loud alert. |
| Receive → Off | After unbind synchronizes, no further alerts to this device for that Bell. |
| Phone offline, sender sends state, phone reconnects/foregrounds | Latest state is recovered without rolling back to an older version. Foreground retry backs off 2–60 seconds; suspended iOS execution is not guaranteed. |
| Offline Create / Off / Terminal close, then reconnect and relaunch | Desired operations retry; retired/deleted owners must not resurrect. Close only disposable test Terminals. Verify server effects with operator logs if UI is inconclusive. |
| Same Ask on two bound devices | First valid verdict wins; other response must report resolved elsewhere, not claim its own choice won. Requires a genuinely shared/bound Bell; do not invent a second independent Bell as a substitute. |
| Actual APNs token rotation | New endpoint works with stable Bell identity, no duplicate binding. Native fixtures cover this logic; physical token rotation is still unverified and not reliably forced on demand. |
| Missing target / notification permission denied | No crash or command execution; fallback and unavailable-alert behavior recorded honestly. |

## 7. Failure triage and what is not yet proven

- Enrollment401: verify the eligible Apple-signed entitlement, signed bundle, environment and absence of a dev purchase token. Do not solve it with a production bypass.
- HTTP202 but no notification: check notification permission/Focus, Receive level, actual completed bind, APNs sandbox vs production, and provider topic/team. Ask operator for sanitized APNs rejection details.
- Encrypted fallback instead of title: verify NSE is embedded and signed, shared group/key access and the correct Bell READ secret. A fallback notification is not decryption success.
- No Ask buttons: launch the installed build once unlocked to register categories; use a fresh unexpired Ask and expand it.
- Origin/config error: old saved diagnostics can override build defaults. Inspect settings without deleting normal app data or transplanting credentials.

Prior physical evidence covers private-sandbox encrypted Ring, locked/restarted routing, offline state recovery and Approve with verified MAC. Production health/auth gates and signed builds passed. **Real paid-account enrollment and notification delivery through the new production topic still need Carlos's device test.** Physical token rotation, offline mutation edge cases and freshness/ownership UI are not declared complete. No Live Activity or arbitrary-choice Ask coverage is implied.

Send back: commit, Xcode/iOS versions, signed bundle/team, APNs environment, entitlement product (no transaction JWS), pass/fail for each row, timestamps and sanitized HTTP/APNs errors. Never include sender capabilities or private keys.
