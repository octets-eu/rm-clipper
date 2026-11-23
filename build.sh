#!/bin/bash
# Builds build/RM-Clipper.app with swiftc (no Xcode needed).
#   ./build.sh          build
#   ./build.sh run      build, stop a running copy, start the new one
set -euo pipefail
cd "$(dirname "$0")"

APP=build/RM-Clipper.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/rmpp.conf "$APP/Contents/Resources/"
swiftc -O -wmo -swift-version 5 -o "$APP/Contents/MacOS/rm-clipper" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
# Ad hoc signature so the Local Network permission sticks across rebuilds.
codesign -s - --force "$APP" 2>/dev/null
echo "Built $APP"

if [ "${1:-}" = "run" ]; then
  pkill -x rm-clipper 2>/dev/null || true
  while pgrep -x rm-clipper >/dev/null; do sleep 0.2; done   # it closes its SSH connections first
  open "$APP"
fi
