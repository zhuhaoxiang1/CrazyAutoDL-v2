#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hunao-region-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
  -framework SwiftUI -framework AppKit \
  "$ROOT/Sources/Market.swift" \
  "$ROOT/Sources/AutoDLAPI.swift" \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/Accounts.swift" \
  "$ROOT/Sources/TokenStore.swift" \
  "$ROOT/Sources/AutoDLSession.swift" \
  "$ROOT/Sources/Theme.swift" \
  "$ROOT/Tests/RegionAlertTests.swift" \
  -o "$TEST_DIR/RegionAlertTests"
"$TEST_DIR/RegionAlertTests"
