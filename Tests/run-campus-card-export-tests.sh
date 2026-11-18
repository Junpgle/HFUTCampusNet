#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BIN="$(mktemp /tmp/campus-card-export-tests.XXXXXX)"
TEST_CACHE="$(mktemp -d /tmp/campus-card-export-swift-cache.XXXXXX)"
trap 'rm -f "$TEST_BIN"; rm -rf "$TEST_CACHE"' EXIT

swiftc \
    -module-cache-path "$TEST_CACHE" \
    -parse-as-library \
    "$ROOT/HFUTCampusNet/Models.swift" \
    "$ROOT/HFUTCampusNet/ElectricityModels.swift" \
    "$ROOT/HFUTCampusNet/CourseModels.swift" \
    "$ROOT/HFUTCampusNet/EmptyClassroomModels.swift" \
    "$ROOT/HFUTCampusNet/LibraryBorrowModels.swift" \
    "$ROOT/HFUTCampusNet/CampusCalendarService.swift" \
    "$ROOT/HFUTCampusNet/CourseScheduleService.swift" \
    "$ROOT/HFUTCampusNet/SettingsManager.swift" \
    "$ROOT/HFUTCampusNet/AcademicAndCardModels.swift" \
    "$ROOT/HFUTCampusNet/CampusCardBillExporter.swift" \
    "$ROOT/Tests/CampusCardBillExporterTests.swift" \
    -o "$TEST_BIN"
"$TEST_BIN"
