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
