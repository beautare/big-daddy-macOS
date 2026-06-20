#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/Release/BigDaddy.app"
DIST_DIR="${ROOT_DIR}/dist"
STAGING_DIR="${BUILD_DIR}/staging"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${DIST_DIR}"

swift build --package-path "${ROOT_DIR}" -c release

cp "${ROOT_DIR}/.build/release/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  codesign --force --sign "-" "${APP_DIR}"
else
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

mkdir -p "${STAGING_DIR}"
cp -R "${APP_DIR}" "${STAGING_DIR}/BigDaddy.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -srcfolder "${STAGING_DIR}" \
  -volname "BigDaddy Installer" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDZO \
  "${DIST_DIR}/BigDaddy-v1.0.0.dmg"

if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${DIST_DIR}/BigDaddy-v1.0.0.dmg"
fi

echo "DMG: ${DIST_DIR}/BigDaddy-v1.0.0.dmg"
