#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift test -Xswiftc -warnings-as-errors
./scripts/build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'invalid release version: %s\n' "$version" >&2
    exit 1
fi

stage_dir=$(mktemp -d "$PWD/dist/.release.XXXXXX")
release_path="$PWD/dist/release"
cleanup() {
    if [ -d "$stage_dir/previous" ] && [ ! -e "$release_path" ]; then
        mv "$stage_dir/previous" "$release_path"
    fi
    rm -r "$stage_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_dir="$stage_dir/kinesis-$version"
output_dir="$stage_dir/release"
mkdir -p "$source_dir/design" "$output_dir"
# Copy only the source release, never the workspace or its local recordings.
rsync -a --exclude='.DS_Store' Sources Tests Packaging scripts docs "$source_dir/"
cp Package.swift README.md .gitignore "$source_dir/"
cp design/kinesis-links.svg "$source_dir/design/"
ditto -c -k --norsrc --noextattr --keepParent "$source_dir" "$output_dir/kinesis-$version-source.zip"
ditto -c -k --norsrc --noextattr --keepParent dist/Kinesis.app "$output_dir/Kinesis-$version-local.zip"
cp docs/release-notes.md "$output_dir/release-notes.md"
(
    cd "$output_dir"
    shasum -a 256 "kinesis-$version-source.zip" "Kinesis-$version-local.zip" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

if [ -e "$release_path" ]; then mv "$release_path" "$stage_dir/previous"; fi
mv "$output_dir" "$release_path"
printf '\nRelease files: %s\n' "$release_path"
printf 'The local app archive is not notarized. Public binary distribution needs Developer ID signing and notarization.\n'
