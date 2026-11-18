#!/bin/bash
# Double-click in Finder (or: bash tool/run_tests_mac.command).
# Runs analyze, the responsive suite, the complete suite and the macOS release
# build, writing full logs to verify_logs/ so they can be reviewed.
cd "$(dirname "$0")/.." || exit 1
export PATH="$HOME/Desktop/flutter/bin:$PATH"
L=verify_logs
mkdir -p "$L"
: > "$L/ui_summary.txt"
step() { # name, command...
  local name=$1; shift
  echo "== $name: $*"
  "$@" > "$L/ui_$name.txt" 2>&1
  local rc=$?
  echo "$name exit=$rc" | tee -a "$L/ui_summary.txt"
}
flutter --version > "$L/ui_00_version.txt" 2>&1
step 01_pub_get flutter pub get
step 02_analyze flutter analyze --no-fatal-infos
step 03_responsive flutter test test/responsive_test.dart --reporter expanded
step 04_all_tests flutter test --reporter expanded
step 05_build_macos flutter build macos --release
# Performance benchmark on a generated test database (never the real data).
rm -rf "$L/perf_db_large"
step 06_perf_seed dart run tool/perf/seed.dart "$L/perf_db_large" 10000 50000 10000
step 06_perf dart run tool/perf/bench.dart "$L/perf_db_large" large
grep -E "^\S.*(\+[0-9]+|-[0-9]+).*:" "$L/ui_04_all_tests.txt" | tail -1 >> "$L/ui_summary.txt"
echo "DONE" >> "$L/ui_summary.txt"
cat "$L/ui_summary.txt"
