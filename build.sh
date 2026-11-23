#!/usr/bin/env bash
# Builds AirMonitor.app.
#
#   ./build.sh               build AirMonitor.app
#   ./build.sh --install     ...and copy it to /Applications and launch it
#   ./build.sh --dmg         ...and create AirMonitor-<version>.dmg (drag-to-Applications installer)
#   ./build.sh --universal   build for both Apple Silicon and Intel Macs (needs full Xcode)
#
# Options can be combined, e.g.  ./build.sh --universal --dmg
#
# Optional, to share the DMG with other Macs without Gatekeeper warnings (Apple Developer account needed):
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"   sign with your Developer ID certificate
#   NOTARY_PROFILE=airmonitor                                 also notarize the DMG (see README)
set -euo pipefail
cd "$(dirname "$0")"

APP="AirMonitor.app"
INSTALL=0
MAKE_DMG=0
UNIVERSAL=0
for arg in "$@"; do
  case "${arg}" in
    --install)   INSTALL=1 ;;
    --dmg)       MAKE_DMG=1 ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "Unknown option: ${arg}"; exit 1 ;;
  esac
done

# If full Xcode is installed but xcode-select points to the Command Line Tools, use Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]] \
   && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "Using Xcode.app instead of the Command Line Tools"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Error: no Swift compiler found. Install Xcode or run: xcode-select --install"
  exit 1
fi

SWIFT_ARGS=(-c release)
if [[ "${UNIVERSAL}" == 1 ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Building (release)..."
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "==> Packaging ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/AirMonitor" "${APP}/Contents/MacOS/AirMonitor"
cp Support/Info.plist "${APP}/Contents/Info.plist"

echo "==> Drawing the app icon..."
ICON_TMP="$(mktemp -d)"
if swift Support/make-icon.swift "${ICON_TMP}/AppIcon.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "${ICON_TMP}/AppIcon.iconset" -o "${APP}/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "Warning: couldn't create the app icon (the app works fine without it)"
fi
rm -rf "${ICON_TMP}"

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "==> Signing with: ${SIGN_ID}"
  codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${APP}"
else
  codesign --force --sign - "${APP}" >/dev/null 2>&1 || echo "Warning: codesign failed (the app will most likely still run)"
fi

echo "==> Done: $(pwd)/${APP}"

if [[ "${MAKE_DMG}" == 1 ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
  DMG_NAME="AirMonitor-${VERSION}.dmg"
  echo "==> Creating ${DMG_NAME}..."
  STAGE="$(mktemp -d)"
  cp -R "${APP}" "${STAGE}/"
  ln -s /Applications "${STAGE}/Applications"     # so you can drag the app onto it
  rm -f "${DMG_NAME}"
  hdiutil create -volname "AirMonitor ${VERSION}" -srcfolder "${STAGE}" -format UDZO -ov "${DMG_NAME}" >/dev/null
  rm -rf "${STAGE}"

  if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --timestamp --sign "${SIGN_ID}" "${DMG_NAME}"
  fi
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${SIGN_ID:-}" ]]; then
      echo "Error: notarization needs SIGN_ID (a Developer ID Application certificate)"
      exit 1
    fi
    echo "==> Notarizing (usually takes a few minutes)..."
    xcrun notarytool submit "${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DMG_NAME}"
  fi
  echo "==> DMG ready: $(pwd)/${DMG_NAME}"
fi

if [[ "${INSTALL}" == 1 ]]; then
  pkill -x AirMonitor 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/${APP}"
  cp -R "${APP}" /Applications/
  open "/Applications/${APP}"
  echo "==> Installed to /Applications and launched. Look at the top right of your menu bar!"
fi
