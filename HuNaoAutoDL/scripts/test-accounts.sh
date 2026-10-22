#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hunao-account-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
  "$ROOT/Sources/AutoDLSession.swift" \
  "$ROOT/Sources/TokenStore.swift" \
  "$ROOT/Sources/Accounts.swift" \
  "$ROOT/Tests/AccountStoreTests.swift" \
  -o "$TEST_DIR/AccountStoreTests"
"$TEST_DIR/AccountStoreTests"
