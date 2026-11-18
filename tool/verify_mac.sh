#!/bin/bash
# Runs the full verification on macOS and writes logs to verify_logs/.
# Usage (from the project folder):  bash tool/verify_mac.sh
cd "$(dirname "$0")/.." || exit 1
LOG=verify_logs
mkdir -p "$LOG"
: > "$LOG/summary.txt"
step() { # name, command...
  local name=$1; shift
  echo "==> $name"
  { echo "\$ $*"; "$@"; } > "$LOG/$name.txt" 2>&1
  local code=$?
  echo "$name exit=$code" | tee -a "$LOG/summary.txt"
  return $code
}
step 01_flutter_version flutter --version
if [ ! -d macos ]; then
  step 02_create_macos flutter create --platforms=macos --project-name al_aqsa_cctv --org com.alaqsa .
fi
# Desktop app needs to print, read the logo and write backups to any folder (USB):
# turn off the macOS App Sandbox for this development build.
for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  [ -f "$f" ] && /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$f" >/dev/null 2>&1
done
step 03_pub_get flutter pub get
step 04_deps flutter pub deps --style=compact
step 05_analyze flutter analyze
step 06_test flutter test --reporter expanded
step 07_build_macos flutter build macos --release
# Exact resolved versions of the packages that matter (name + version from pubspec.lock).
awk '/^  [a-z_]+:$/{n=$1} /^    version:/{gsub(/"/,"",$2); print n, $2}' pubspec.lock \
  | grep -E "^(archive|image|pdf|printing|xml|petitparser|hive_ce|flutter_riverpod|path_provider|intl|crypto):" > "$LOG/key_versions.txt"
if grep -q "^image: 4.11.0$" "$LOG/key_versions.txt"; then
  echo "WARNING: image 4.11.0 is locked (broken PNG decoder with archive 4.0.x)" | tee -a "$LOG/summary.txt"
fi
echo
echo "Done. Results:"; cat "$LOG/summary.txt"
