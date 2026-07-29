#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Voce Dev"
BUNDLE_ID="io.voceapp.voce.dev"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/dev-run"
BUILT_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALL_BUNDLE="/Applications/$APP_NAME.app"
APP_BINARY="$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/Voce.xcodeproj" \
  -scheme VoceDev \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=-

test -d "$BUILT_BUNDLE"
rm -rf "$INSTALL_BUNDLE"
/usr/bin/ditto "$BUILT_BUNDLE" "$INSTALL_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$INSTALL_BUNDLE"

INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_BUNDLE/Contents/Info.plist")"
if [[ "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Unexpected bundle identifier: $INSTALLED_BUNDLE_ID" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "io.voceapp.voce"'
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
