#!/bin/bash
# Builds the dev app from this checkout and installs it as /Applications/Kinesis Dev.app,
# next to the release Kinesis.app. Run it again after any change to rebuild.
#
#     scripts/install-dev.sh
set -euo pipefail
cd "$(dirname "$0")/.."

target="/Applications/Kinesis Dev.app"

# Sign with the same Developer ID as the release, so macOS keeps one Accessibility
# approval and one keychain approval for both apps.
developer_id=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2; exit }')
KINESIS_SIGNING_IDENTITY="${KINESIS_SIGNING_IDENTITY:-$developer_id}" ./scripts/build.sh --dev

# Quit whichever Kinesis is running, dev or release. Two at once fight over the band.
for _ in $(seq 20); do
    pgrep -x Kinesis >/dev/null || break
    osascript -e 'tell application id "local.callbacked.kinesis" to quit' >/dev/null 2>&1 || true
    sleep 1
done
if pgrep -x Kinesis >/dev/null; then
    printf 'kinesis did not quit. quit it from the menu bar and run this again.\n' >&2
    exit 1
fi

rm -rf "$target"
ditto dist/Kinesis.app "$target"
open "$target"
printf 'Installed %s from %s (%s)\n' "$target" "$(git branch --show-current)" "$(git rev-parse --short HEAD)"
