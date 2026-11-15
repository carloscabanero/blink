#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Keep generated binaries outside the repository. No APNs/network calls.
binary="$(mktemp -u "${TMPDIR:-/tmp}/blink-bell-codec.XXXXXXXX")"
swiftc Blink/Bell/BellMockPush.swift Tools/BellWireTests/main.swift -o "$binary"
"$binary" Tools/BellWireTests/relay-vectors.json
