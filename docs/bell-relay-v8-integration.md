# Relay v8 integration — in progress

Branch `feature/relay-v8-integration` is an incremental adaptation of Carlos's `bell-client-v8`, not an end-to-end working client yet.

Implemented:

- Production Relay v1 envelope decoder alongside mock fixtures, explicit hex Bell IDs and base64url message IDs, version/state/progress validation.
- ChaCha20-Poly1305 NSE decryption with the Relay's exact AAD and separate READ secret; no MANAGE key access. Encrypted content falls back unchanged on missing/wrong keys or authentication failure. Plaintext is accepted only by bindings permitting it.
- Protected routing lookup now optionally stores content_secret; the app must populate it through real provisioning (not implemented yet).
- Production alert fallback resolves Bell IDs without requiring successful decryption. Real background envelopes route into the existing fetch entry point, which remains a stub.
- Last-known status snapshot persistence and rejection of non-increasing Relay state versions. Real state fetching/freshness and separate local-observation ordering remain unfinished.

Verification:

`Tools/BellWireTests/run.sh` runs ten independent checks against a copy of the Relay crypto vectors, including successful Go/Swift decryption, wrong key, tampered AAD, version and range checks, and Ring-only state behavior. No network or APNs calls. Bell model, codec, binding store, Tower, mock adapter and WorkURL typecheck against the iOS Simulator SDK using a temporary logger stub; this is not proof of full app compilation. All changed Swift sources parse.

Build setup: developer_setup.xcconfig copied from the supplied team template (ignored local file); submodules initialized, root package dependencies resolved. The full Blink build initially fails for missing xcfs binary artifacts/package products. Framework resolution has been started; do not equate dependency preparation with a successful build.

Still required: real async Relay transport/enrollment/signatures and UI integration, durable desired operations and revocation retries, actual state reconciliation, snapshot cleanup/freshness, Ask, full app build/signing and real APNs/device validation. Existing `MockBellRelay` remains the Tower default. No automatic live traffic is enabled.

Paired physical iPhone and iPad are visible via devicectl. No app installation, signing-account changes, or APNs pushes have been performed. Provider .p8 remains outside Git and unused.

## Live transport checkpoint

`LiveBellRelay` is now the shared Tower backend. The mock remains explicitly injectable for existing tests. Synchronous Terminal actions write a protected, backup-excluded operation journal; URLSession performs network I/O asynchronously. Creation uses owner session UUID to preserve identity across retry/restart. Desired binding and revocation records retain the management seed. Acknowledgements compare operation revisions, so stale replies cannot clear newer desired state. Retired records never send create. Read errors do not reset the journal. Journal credentials are scoped to their configured Relay origin.

The adapter implements enrollment, mint-authorized create, Ed25519 Bell-Key proofs, separate endpoint capability enrollment/rotation, bind/unbind/delete and per-Bell signed batch state retrieval (200 entries per request). Snapshots decrypt with READ secrets and apply monotonic versions. Device-wide hints refresh all known Bells. Only HTTPS or explicit HTTP loopback is accepted; redirects are refused by the production session. Sender copying exports token.content_secret, never the management seed.

Configuration is explicit, with no default production URL: `BellRelayURL` and `BellAPNsEnvironment` UserDefaults (e.g. Xcode launch arguments) and `BELL_PAID_TOKEN` scheme environment for initial sandbox enrollment. Topic is the signed app bundle ID. This initial enrollment input is a development/test hook, not a completed StoreKit purchase integration. The protected journal retains minted device credentials for later launches. The updated Relay must be hosted at the configured URL before real traffic works. The old deployed Relay does not support the new endpoint routes.

`Tools/BellTransportTests/run.sh` performs 11 native transport/recovery checks via an intercepted URLSession fixture: Go-compatible request proofs verified cryptographically, stable owner creation, lost bind/restart identity retention, same-create retry, no rebind on endpoint rotation, encrypted versioned snapshot read, durable unbind and offline retirement without resurrection. CryptoKit's generated signature bytes differed from the stored Go signature; checking exact signature equality failed, whereas both signatures verify over identical Go proof bytes with the published verifier. The test now checks interoperability rather than requiring identical signature output. This fixture is not a live Relay HTTP/device test.

Build dependencies completed, and the complete Blink iOS app build succeeded with CODE_SIGNING_ALLOWED=NO. Root package resolution uses the repository's current ranges (including current resolved versions), not proof of Carlos's exact dependency environment. Existing Objective-C analyzer warnings remain. Signed build for the paired iPhone was attempted with provisioning updates; CLI Xcode reports No Accounts and missing team development profiles/certificates, including app and NSE. No device install or APNs send occurred. Tanguy's reported GUI account state and this CLI failure need reconciliation, not blind account replacement.

Remaining: real StoreKit enrollment input; server-side full operation-id/stale-create/rekey contract; client retry scheduling/backoff (currently lifecycle/token/explicit action triggers), fresh/stale UI and lifecycle ownership recovery; Ask (both sides); staging deployment and real-device signed routing/background/APNs tests. Pending operations are saved but not exposed as accepted bindings in the response (`pending=true`); menu selection still represents desired local state. A failed synchronization can delay other records until a later lifecycle retry. Retired journal credentials are retained, not automatically compacted. No production changes.

## Verified sandbox Ring checkpoint (2026-11-12)

The signed development app is installed on the paired iPhone. Real client enrollment/Bell creation/stable endpoint binding → private HTTPS Relay → sandbox APNs → NSE decryption → original Terminal routing has been confirmed by the user. Locked/suspended delivery and process-restart routing also passed. During a private Relay endpoint outage, the app preserved seq3 and recovered/decrypted seq4 after reconnection/relaunch; no duplicate device/Bell/binding appeared.

Configuration now validates and persists explicitly supplied BellRelayURL/BellAPNsEnvironment to UserDefaults so ordinary launches keep the sandbox target. It does not persist the enrollment environment token. The journal retains its existing origin guard and protected credentials. Foreground refresh failures schedule exponential retry (2–60 seconds); background/suspended recovery still depends on lifecycle/APNs opportunities, not guaranteed execution. Concurrent refresh requests coalesce with one follow-up so an APNs token arriving during enrollment is not lost. Individual failed Bell operations remain pending but no longer starve unrelated Bells.

18 native transport/configuration/recovery checks and ten codec checks pass. Signed full app build and bundle verification pass. Device preference copy confirmed persistent URL/environment; a no-argument launch connected to the existing Relay. During a new endpoint outage, the device logged timed foreground retries; after it backgrounded, restoring/foregrounding recovered. This is not proof of a fully background retry scheduler. Sandbox is tailnet-private on the Mac Studio, not a durable hosted production service.

Unfinished: Ask (server rejects with501; no authoritative ask_id/expiry/verdict storage/atomic first-valid resolution/result lookup, and no iOS action submission/outbox). StoreKit enrollment hookup, server full operation/rekey contract, ownership/freshness UI, physical OS-token rotation and queued offline create/unbind/delete verification also remain. Do not describe this checkpoint as the entire v8 feature being complete.

## Confirm Ask implemented and exercised

Encrypted Approve/Deny Ask now works with the integration Relay. Startup registers BELL_CONFIRM actions requiring local authentication but not foreground launch. NSE decrypts the prompt and validates Ask ID matches authenticated message ID before enabling its actions; expired prompts lose actions. Custom action callbacks do not route a Space/Terminal. Before sending, LiveBellRelay persists the original selected verdict and HMAC in its protected journal; failed submissions survive restart. Synchronization retries saved submissions and stores accepted/resolved_elsewhere/expired outcomes; later taps cannot overwrite the original saved choice. This does not promise execution while iOS suspends the app. Generic choice Ask is not implemented.

22 native transport/configuration/recovery/Ask checks and ten codec checks pass, including lost-response/restart persistence, competing-result truthfulness and expiry. Signed full app build passes, bundle signature verifies, latest build installed. Physical-device test: after the new app launched and registered categories, user selected Approve; real signed Relay verdict200, sender GET result200 accepted/approve, and returned VerdictMAC verified using the sender READ secret. Two verdict requests converged on the same result. Initial remote launch was denied while phone locked; those failures must not be mistaken for category registration success.

Remaining broader production gates: actual StoreKit enrollment integration; durable hosted deployment rather than Mac-hosted tailnet sandbox; full server operation/rekey conflict contract; ownership/freshness UI; actual OS-token-rotation and queued offline mutation physical-device coverage. Confirm Ask is no longer unimplemented, but these gates are not declared passed by the sandbox test.

## Production client enrollment

An unconfigured installation targets https://bell.blink.sh. Explicit saved sandbox configuration still wins and origin-scoped journals cannot silently migrate credentials. Initial enrollment uses a locally verified nonrevoked/unexpired StoreKit2 current entitlement JWS when the test-only environment token is absent; the Relay is the final bundle/product/purchase verifier. No purchase is initiated automatically. Existing deployments must enable the matching topic/team/bundle and agree their eligible product allowlist before new-app onboarding is claimed working. HTTP410 permanently retires local pending records rather than retrying stale creates forever. Real StoreKit enrollment still requires an eligible Apple-account transaction on the device; fixture and signed compilation do not prove a purchase was accepted.

## All-paid-plan production policy

Bell access includes these active paid-plan product IDs: blink_plus_1y_2999, blink_shell_plus_1y_1999, blink_build_basic_1m_799, blink_plus_build_1m_999. Client selection filters to the same set before sending the signed entitlement; the server independently verifies product eligibility, app bundle, environment, signature, expiry and revocation. The zero-price classic/unlimited unlock SKU is not a paid subscription plan. New release builds default APNs registration to production; debug builds default to sandbox. Explicit saved diagnostic settings still override those defaults.

The production Relay supports both original com.blink.shell and sh.blink.blinkshell topics through separate Apple-team keys. Development purchase tokens are disabled; signed StoreKit sandbox transactions remain allowed for TestFlight as in the previous deployment. Production HTTP health/authentication checks are not proof of a real Apple-account purchase being accepted. Keep the private sandbox test journal/credentials scoped to its original origin; do not transplant dev mint credentials into production to fake that check.

Release builds do not emit CLI diagnostic APNs device tokens. These diagnostics remain debug-only for deliberate local sandbox testing; do not attach raw debug logs to public issues.
