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

Expected: 10 codec checks and the transport/config/recovery/Ask check count printed by the runner (including explicit test-token forwarding, enrollment rejection, missing/empty APNs tokens and recovery). These exercise encrypted wire compatibility, signatures, retry identity, durable offline operations, state ordering and verdict recovery through fixtures. They do **not** prove StoreKit, APNs or physical-device delivery.

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

Use `sandbox` for a development-signed build. TestFlight/App Store builds use `production` APNs (even though TestFlight StoreKit purchases are sandbox transactions). The APNs environment and StoreKit environment are separate. Debug defaults to sandbox; Release defaults to production. Debug launch overrides win for that launch; Release uses build settings and ignores diagnostic overrides.

Remove `BELL_PAID_TOKEN` from the scheme environment when testing production. There is no development-purchase bypass on production. Launch once unlocked so notification actions register; allow notifications in iOS Settings.

## 4. Prove paid enrollment — this is still an open production gate

The signed-in Apple account needs a real, locally verified current entitlement for one of:

- `blink_plus_1y_2999`
- `blink_shell_plus_1y_1999`
- `blink_build_basic_1m_799`
- `blink_plus_build_1m_999`

The classic/unlimited zero-price unlock alone does not qualify. Use the app's normal purchase/restore flow if needed; this test does not require a new purchase when an eligible entitlement already exists. A local Xcode StoreKit configuration is not proof that the production server will accept an Apple-signed transaction. Turn it off for the real enrollment test.

In a test Terminal, open Quick Actions → Bell → Create Bell, then Receive → Loud. Save the copied `token.content_secret` privately. Creation is asynchronous: the token dialog alone does not mean the server accepted enrollment, creation or binding. Confirm successful enrollment/bind via device diagnostics and an actual delivered Ring below. Server logs, if needed, require the operator; you do not need production SSH access to run the client test.

XCConfig settings survive icon launches; diagnostic launch arguments apply only to the corresponding Debug launch. An old private sandbox journal cannot silently migrate to production: use a separate test installation/container for another Relay origin. Do not delete your normal app data to work around the origin guard.

## 4a. Development enrollment without a paid Apple transaction

This is a **separate, private development Relay**, not a flag to enable on `bell.blink.sh`. You need Go 1.26+, Docker, and a Mac endpoint reachable over trusted HTTPS from the phone. A test token is not a Bell SEND token, APNs device token or mint key.

In a separate server checkout:

```bash
git clone https://github.com/blinksh/bell.git bell-relay-dev
cd bell-relay-dev
git checkout af99b09
make up
make build
BELL_ADDR=127.0.0.1:8787 BELL_PURCHASE=dev BELL_PUSH=log \
  BELL_APNS_TOPICS=sh.blink.blinkshell ./bin/relay
```

Use your actual signed **app** bundle ID for `BELL_APNS_TOPICS` (`com.blink.shell` if that is your build). These commands start local Postgres/Redis on 5433/6380 and a development Relay on Mac loopback8787. If those ports/container names are already in use, use a separate fixture configuration rather than modifying another service.

In another terminal on that Mac, check enrollment directly:

```bash
curl --fail --silent --show-error -o /dev/null -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  --data '{"paid_token":"dev:carlos"}' http://127.0.0.1:8787/devices
```

Expected HTTP201. This creates a disposable test device; it does not configure the iPhone or supply the iPhone's mint key. HTTP401 means the server did not accept development purchases/the token format. Valid names match `dev:[a-z0-9][a-z0-9._-]{0,63}`. Never run this probe against production expecting dev acceptance.

Expose the loopback Relay through a **private trusted HTTPS reverse proxy** reachable by your phone. For example, if you already use Tailscale on both Mac and phone, inspect `tailscale serve status` first; if HTTPS8443 is unused, run on the Mac:

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:8787
```

Use the exact HTTPS origin it reports, including `:8443`, with no path. Do not overwrite an existing Serve route or enable public Funnel. HTTPS must be enabled for the tailnet and phone ACLs must permit access. A trusted HTTPS proxy you already operate is also fine. `http://127.0.0.1:8787` on the iPhone means the **iPhone**, not your Mac. The client rejects plain HTTP LAN addresses and untrusted TLS; do not disable certificate verification. Stop only the test route afterwards (`tailscale serve --https=8443 off` for the route above).

In **Xcode → Product → Scheme → Edit Scheme → Run → Arguments**:

1. Under **Arguments Passed On Launch**, enable these two entries, replacing the origin with your private HTTPS address:

   ```text
   -BellRelayURL https://YOUR-MAC.YOUR-TAILNET.ts.net:8443
   -BellAPNsEnvironment sandbox
   ```

2. Under **Environment Variables**, add and enable:

   | Name | Value |
   | --- | --- |
   | `BELL_PAID_TOKEN` | `dev:carlos` |

3. Stop the running app, then launch through Xcode. The environment is read when the Relay adapter is initialized. Passing `-BELL_PAID_TOKEN dev:carlos` as launch arguments, setting it only in the Mac shell, or opening the app from its icon does **not** inject that environment variable. Do not commit a shared scheme containing real enrollment secrets.
4. Use a test installation already scoped to this private origin (or a separately signed test variant with matching server topic). An existing production/private-origin journal must not be transplanted or erased merely to switch environments.
5. Create a disposable Bell and select Loud. A correctly signed physical device is still needed to obtain an APNs token for binding, **even when the development server logs pushes**. The simulator is not evidence of this device flow.

`BELL_PUSH=log` proves enrollment, HTTP operations and server-side dispatch attempts; it does **not** send a notification. For real development APNs delivery, restart this private Relay with the same database and `BELL_PURCHASE=dev`, but replace `BELL_PUSH=log` with:

```bash
BELL_ADDR=127.0.0.1:8787 BELL_PURCHASE=dev BELL_PUSH=apns \
  BELL_APNS_TOPICS=YOUR_SIGNED_APP_BUNDLE_ID \
  BELL_APNS_KEY_FILE=/private/path/to/AuthKey.p8 \
  BELL_APNS_KEY_ID=YOUR_KEY_ID BELL_APNS_TEAM_ID=YOUR_TEAM_ID ./bin/relay
```

The key must authorize your signed app's topic/team. Keep it outside Git. Use `sandbox` in the development-signed iPhone app; the Relay uses the endpoint's environment to select APNs. For the sender commands below, add `-relay https://YOUR-MAC.YOUR-TAILNET.ts.net:8443` to **every send and lookup**; otherwise the helper targets production.

## 4b. Diagnose Carlos's reported error

Before this update, **“Relay enrollment credentials are unavailable.”** was also thrown for a missing APNs token and invalid local Bell keys. It did not establish that the test token failed to reach the Relay.

The updated build separates the causes:

| New diagnostic | Meaning / next step |
| --- | --- |
| No eligible paid entitlement or enrollment token | Nothing usable was found locally; no enrollment POST was sent. Check the enabled Xcode Run environment variable and relaunch through Xcode, or restore an eligible Apple purchase for production. |
| Relay enrollment failed (HTTP401) | An enrollment POST was sent and rejected. Confirm the selected origin, token format and server purchase mode. Production rejects `dev:carlos`. |
| Relay enrollment failed (another HTTP code) | Enrollment reached an HTTP endpoint but failed; inspect the status and sanitized server logs. Do not assume a credential problem for rate limits/server errors. |
| Waiting for an APNs device token | Enrollment is past the purchase-input gate; binding remains pending. Check physical-device signing, push entitlement, connectivity and APNs registration errors. Changing the purchase token will not fix APNs. |
| Saved Bell credentials invalid / device ID missing | Local journal/key problem, not a missing test token. Preserve the journal and report the error; do not delete it or expose it publicly. |
| Relay configuration invalid / saved origin differs | Validate the URL/environment and use the installation's original origin, or a separate test installation. |

Inspect Xcode device console for the Bell synchronization error and APNs registration failure. If needed, break at `LiveBellRelay.synchronize` and inspect only `configuration?.baseURL`, the injected purchase provider result availability (not its secret value) and `apnsToken?.count`—not their secret contents. Record whether `/devices` reached the selected server. A pending token dialog is not server acceptance. The previous generic message alone cannot diagnose Carlos's original run; retest with the updated PR.

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

## 9. Operation acknowledgment and composition boundaries

The Journal remains a durable desired-state snapshot. Create/bind returning locally is **not** remote acceptance. Open **Relay Status** in the Bell menu (or leave the token dialog open): it subscribes to per-Bell status and updates from pending to confirmed or a retry reason. Confirmation covers the current desired revision, including binding; it does not prove notification delivery. Received Bell content/state remains a separate publisher.

To test, stop your development Relay, create a Bell, and leave the status dialog open. It must remain pending/retrying, never confirmed. Restart the Relay with the app foregrounded: bounded retries should confirm the same Bell/token. Repeat with missing APNs registration; the dialog must explain the waiting condition. Change Receive while a bind is outstanding: an older reply must not confirm the new operation. Restart Blink offline: pending/error state must survive. These device/UI scenarios still require a manual retest.

App composition lives in `AppDelegate+Bell.swift`. Add these optional settings to an existing `developer_setup.xcconfig` (new setups get them from the template):

```xcconfig
BELL_RELAY_URL = https:/$()/bell.blink.sh
BELL_RELAY_ENABLED = YES
// Leave empty for Debug=sandbox, Release=production, or set explicitly.
BELL_APNS_ENVIRONMENT =
```

`BELL_RELAY_ENABLED = NO` disables Relay operations with an explicit error; it never silently switches to the mock. Tests inject mock/live clients and a `BellPurchaseProofProvider`. Production purchase lookup uses the product constants from `EntitlementsManager`, requests a fresh verified StoreKit proof on enrollment attempts, and retries if purchase information was unavailable at startup. Existing enrolled devices keep their saved mint credentials. Debug-only `BELL_PAID_TOKEN` remains the development override; no secret belongs in xcconfig or the plist.

Relay owns queue retries; Tower forwards foreground/inactive and APNs endpoint events. Tower refresh retries concern received state only. Queue mutations do not fetch `/state`. Activation/background hints still reconcile received state; this does not promise background execution. Ask wire/authentication and notification presentation/receipt rules are unchanged.

Cleanup removes acknowledged retired Bell records only when no unresolved Ask needs their credentials, along with their resolved submissions. Active Bell keys and unresolved operations are retained. Completed Ask history for still-active Bells is deliberately retained for idempotent choice recovery; it is not blindly trimmed.
