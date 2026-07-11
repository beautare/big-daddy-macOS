#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/Release/BigDaddy.app"
DIST_DIR="${ROOT_DIR}/dist"
STAGING_DIR="${BUILD_DIR}/staging"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${ROOT_DIR}/BigDaddy/Info.plist")
BUILD_NUMBER=$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null || echo "1")
echo "Building BigDaddy version ${VERSION} (Build ${BUILD_NUMBER})..."

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${DIST_DIR}"

# 同时编译 arm64 + x86_64，产出单个 universal 二进制，覆盖 Apple Silicon 和 Intel
swift build --package-path "${ROOT_DIR}" -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build --package-path "${ROOT_DIR}" -c release --arch arm64 --arch x86_64 --show-bin-path)

cp "${BIN_DIR}/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"

# 临时向打包的 Info.plist 写入构建号，代码库中的源文件保持不变
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_DIR}/Contents/Info.plist"

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  codesign --force --sign "-" "${APP_DIR}"
else
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

mkdir -p "${STAGING_DIR}"
cp -R "${APP_DIR}" "${STAGING_DIR}/BigDaddy.app"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${DIST_DIR}/BigDaddy-v${VERSION}.dmg"

hdiutil create \
  -srcfolder "${STAGING_DIR}" \
  -volname "BigDaddy Installer" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDZO \
  "${DMG_PATH}"

if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${DMG_PATH}"

  # 公证：只有传入了 App Store Connect API Key 才会执行，本地手动打包可以不设置这三个变量跳过
  if [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    echo "Submitting for notarization..."
    xcrun notarytool submit "${DMG_PATH}" \
      --key "${APPLE_API_KEY_PATH}" \
      --key-id "${APPLE_API_KEY_ID}" \
      --issuer "${APPLE_API_ISSUER_ID}" \
      --wait
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
  else
    echo "Skipping notarization (APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER_ID not set)"
  fi
fi

echo "DMG: ${DMG_PATH}"
