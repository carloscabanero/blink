#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp -u "${TMPDIR:-/tmp}/blink-bell-transport.XXXXXXXX")"
swiftc -parse-as-library Blink/Bell/Bell.swift Blink/Bell/BellMockPush.swift Blink/Bell/MockBellRelay.swift Blink/Bell/LiveBellRelay.swift Tools/BellTransportTests/main.swift -o "$binary"
"$binary" Tools/BellWireTests/relay-vectors.json
