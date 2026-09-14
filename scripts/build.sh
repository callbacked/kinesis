#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -f "^$PWD/dist/Kinesis.app/Contents/MacOS/Kinesis$" >/dev/null; then
    printf 'quit kinesis before rebuilding.\n' >&2
    exit 1
fi

build_args=(-c release --arch arm64 --arch x86_64 -Xswiftc -warnings-as-errors)
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
# SwiftPM can retain removed resources in an existing bundle.
if [ -d "$binary_dir/Kinesis_Kinesis.bundle" ]; then
    rm -r "$binary_dir/Kinesis_Kinesis.bundle"
fi
swift build "${build_args[@]}"

mkdir -p dist .build/tools
stage_dir=$(mktemp -d "$PWD/dist/.package.XXXXXX")
app_path="$PWD/dist/Kinesis.app"
staged_app="$stage_dir/Kinesis.app"
cleanup() {
    if [ -d "$stage_dir/previous.app" ] && [ ! -e "$app_path" ]; then
        mv "$stage_dir/previous.app" "$app_path"
    fi
    rm -r "$stage_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/Kinesis" "$staged_app/Contents/MacOS/Kinesis"
cp -R "$binary_dir/Kinesis_Kinesis.bundle" "$staged_app/Contents/Resources/"
cp Packaging/Info.plist "$staged_app/Contents/Info.plist"
swiftc -parse-as-library Sources/Kinesis/KinesisMark.swift scripts/export-icon.swift -o .build/tools/export-icon
.build/tools/export-icon "$stage_dir/Kinesis.iconset"
iconutil -c icns "$stage_dir/Kinesis.iconset" -o "$staged_app/Contents/Resources/Kinesis.icns"

signing_identity="${KINESIS_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '
        /"Apple Development:/ { count++; identity = $2 }
        END { print (count == 1 ? identity : "-") }
    ')
fi
codesign --force --options runtime --sign "$signing_identity" "$staged_app"
codesign --verify --deep --strict "$staged_app"
lipo "$staged_app/Contents/MacOS/Kinesis" -verify_arch arm64 x86_64
plutil -lint "$staged_app/Contents/Info.plist"

if [ -e "$app_path" ]; then mv "$app_path" "$stage_dir/previous.app"; fi
mv "$staged_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
