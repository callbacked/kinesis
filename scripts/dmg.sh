#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_path="${1:?usage: ./scripts/dmg.sh /path/to/notarized/Kinesis.app}"
case "$app_path" in /*) ;; *) app_path="$PWD/$app_path" ;; esac
codesign --verify --deep --strict "$app_path"
xcrun stapler validate "$app_path"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
expected_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)
if [ "$bundle_id" != "$expected_id" ]; then
    printf 'expected %s, got %s\n' "$expected_id" "$bundle_id" >&2
    exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'invalid release version: %s\n' "$version" >&2
    exit 1
fi
signing_identity="${KINESIS_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '
        /"Developer ID Application:/ { count++; identity = $2 }
        END { if (count == 1) print identity }
    ')
fi
if [ -z "$signing_identity" ]; then
    printf 'set KINESIS_SIGNING_IDENTITY to a Developer ID Application identity.\n' >&2
    exit 1
fi

mkdir -p dist
destination="$PWD/dist/Kinesis-$version.dmg"
if [ -e "$destination" ]; then
    printf 'already exists: %s\n' "$destination" >&2
    exit 1
fi
stage_dir=$(mktemp -d "$PWD/dist/.dmg.XXXXXX")
mount_path="$stage_dir/mount"
mounted=false
cleanup() {
    local result=$?
    if $mounted; then
        if ! hdiutil detach "$mount_path"; then
            printf 'mounted image left at %s\n' "$mount_path" >&2
            return
        fi
    fi
    if [ "$result" -eq 0 ]; then
        rm -r "$stage_dir"
    else
        printf 'packaging files kept at %s\n' "$stage_dir" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$stage_dir/payload" "$mount_path"
ditto "$app_path" "$stage_dir/payload/Kinesis.app"
ln -s /Applications "$stage_dir/payload/Applications"
hdiutil create -volname Kinesis -fs HFS+ -srcfolder "$stage_dir/payload" -format UDRW "$stage_dir/layout.dmg"
hdiutil attach "$stage_dir/layout.dmg" -nobrowse -noautoopen -mountpoint "$mount_path"
mounted=true
osascript - "$mount_path" <<'APPLESCRIPT'
on run argv
    set diskFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        tell folder diskFolder
            open
            set imageWindow to container window
            set current view of imageWindow to icon view
            set toolbar visible of imageWindow to false
            set statusbar visible of imageWindow to false
            set bounds of imageWindow to {250, 150, 810, 480}
            set viewOptions to icon view options of imageWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set position of item "Kinesis.app" to {150, 145}
            set position of item "Applications" to {410, 145}
            update without registering applications
            close
        end tell
    end tell
    delay 2
end run
APPLESCRIPT
sync
hdiutil detach "$mount_path"
mounted=false
image_path="$stage_dir/Kinesis-$version.dmg"
hdiutil convert "$stage_dir/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$image_path"
codesign --force --timestamp --sign "$signing_identity" "$image_path"
codesign --verify --strict "$image_path"
asc notarization submit --file "$image_path" --wait --poll-interval 30s --timeout 1h --output json > "dist/Kinesis-$version-notarization.json"
xcrun stapler staple "$image_path"
xcrun stapler validate "$image_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image_path"
hdiutil verify "$image_path"
mv "$image_path" "$destination"
printf '\nNotarized DMG: %s\n' "$destination"
