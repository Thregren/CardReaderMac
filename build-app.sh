#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/.build/app"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/CardReaderMac.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/CardReaderMac.app"
archive="$project_dir/dist/CardReaderMac.zip"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS"
mkdir -p "$project_dir/dist"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -O -sdk "$sdk" -target arm64-apple-macosx14.0 \
    -module-cache-path "$build_dir/modules" -module-name CardReaderMac \
    "$@" "$project_dir"/Sources/CardReaderMac/*.swift -o "$build_dir/CardReaderMac"
install -m 755 "$build_dir/CardReaderMac" "$app_dir/Contents/MacOS/CardReaderMac"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>射频卡读写器</string>
    <key>CFBundleExecutable</key><string>CardReaderMac</string>
    <key>CFBundleIdentifier</key><string>local.CardReaderMac</string>
    <key>CFBundleName</key><string>CardReaderMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
# Package outside iCloud Drive so Finder metadata cannot interfere with signing.
ditto -c -k --keepParent --norsrc "$app_dir" "$staging_dir/CardReaderMac.zip"
mv -f "$staging_dir/CardReaderMac.zip" "$archive"
printf '%s\n' "$archive"
