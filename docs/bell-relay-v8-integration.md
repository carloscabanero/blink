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
