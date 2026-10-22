#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hunao-sub-account-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
  -framework SwiftUI -framework AppKit \
  "$ROOT/Sources/AutoDLSession.swift" \
  "$ROOT/Sources/TokenStore.swift" \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/Market.swift" \
  "$ROOT/Sources/Accounts.swift" \
  "$ROOT/Sources/Theme.swift" \
  "$ROOT/Sources/AutoDLAPI.swift" \
  "$ROOT/Tests/SubAccountTests.swift" \
  -o "$TEST_DIR/SubAccountTests"
"$TEST_DIR/SubAccountTests"
