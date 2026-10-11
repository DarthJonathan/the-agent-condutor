#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script creates a macOS application bundle." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
conductor_profile=release
if [[ "${1:-}" == "--debug" ]]; then
  conductor_profile=debug
  cargo build --locked
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--debug]" >&2
  exit 2
else
  cargo build --locked --release
fi

conductor_bundle="dist/Agent Conductor.app"
mkdir -p "$conductor_bundle/Contents/MacOS"
install -m 755 "target/$conductor_profile/agent-conductor" "$conductor_bundle/Contents/MacOS/conductor-engine"
mkdir -p target/swift-module-cache
conductor_arch="$(uname -m)"
conductor_swift_options=(-O)
if [[ "$conductor_profile" == "debug" ]]; then
  conductor_swift_options=(-Onone -g)
fi
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -target "$conductor_arch-apple-macosx14.0" \
  -module-cache-path target/swift-module-cache \
  "${conductor_swift_options[@]}" \
  macos/Models.swift macos/MentionEditor.swift macos/EngineStore.swift macos/Views.swift macos/ConductorApp.swift \
  -o "$conductor_bundle/Contents/MacOS/agent-conductor"
cat > "$conductor_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Conductor</string>
  <key>CFBundleDisplayName</key><string>Agent Conductor</string>
  <key>CFBundleExecutable</key><string>agent-conductor</string>
  <key>CFBundleIdentifier</key><string>dev.agentconductor.desktop</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$conductor_bundle"
printf 'Built %s\n' "$conductor_bundle"
