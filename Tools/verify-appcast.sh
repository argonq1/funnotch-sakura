#!/bin/bash
# Checks that every download in the appcast is the file its signature was
# made for — the same check Sparkle does before it will install an update.
#
#   ./Tools/verify-appcast.sh           check appcast.xml in the repo
#   ./Tools/verify-appcast.sh --live    check the feed installed apps read
#
# Run it after uploading release assets, and again after pushing the appcast.
# If anything rebuilds or re-uploads a dmg after it was signed, this is what
# says so, instead of users' update prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEY="${FUNNOTCH_UPDATE_PUBLIC_KEY:-}"
if [ -z "$KEY" ] && [ -f build/FunNotch.app/Contents/Info.plist ]; then
  KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/FunNotch.app/Contents/Info.plist)"
fi
if [ -z "$KEY" ]; then
  echo "ERROR: Set FUNNOTCH_UPDATE_PUBLIC_KEY or build the configured app first" >&2
  exit 1
fi
FEED="appcast.xml"
if [ "${1:-}" = "--live" ]; then
  FEED="${FUNNOTCH_UPDATE_FEED:-https://raw.githubusercontent.com/argonq1/funnotch-sakura/main/appcast.xml}"
fi

exec swift "$ROOT/Tools/VerifyAppcast.swift" "$KEY" "$FEED"
