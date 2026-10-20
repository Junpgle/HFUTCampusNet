#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BIN="$(mktemp /tmp/campus-ai-tests.XXXXXX)"
TEST_CACHE="$(mktemp -d /tmp/campus-ai-swift-cache.XXXXXX)"
trap 'rm -f "$TEST_BIN"; rm -rf "$TEST_CACHE"' EXIT

swiftc \
    -module-cache-path "$TEST_CACHE" \
    "$ROOT/HFUTCampusNet/CampusAIFlowSupport.swift" \
    "$ROOT/HFUTCampusNet/CampusAICasLoginSupport.swift" \
    "$ROOT/Tests/CampusAIFlowSupportTests.swift" \
    -o "$TEST_BIN"
"$TEST_BIN"
