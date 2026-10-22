#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hunao-monitor-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Everything except the @main app entry: the monitor, its model and the views it is wired into compile together.
SOURCES=("${(@f)$(find "$ROOT/Sources" -name '*.swift' ! -name HuNaoAutoDLApp.swift | sort)}")
swiftc -parse-as-library \
  -target arm64-apple-macosx15.0 \
  -framework SwiftUI -framework AppKit -framework WebKit -framework UserNotifications -framework Combine \
  "${SOURCES[@]}" \
  "$ROOT/Tests/MonitorTests.swift" \
  -o "$TEST_DIR/MonitorTests"
"$TEST_DIR/MonitorTests"
