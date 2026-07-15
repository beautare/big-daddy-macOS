#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/Release/BigDaddy.app"
DIST_DIR="${ROOT_DIR}/dist"
STAGING_DIR="${BUILD_DIR}/staging"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# ARCH 控制产出哪种二进制：
#   universal (默认) = arm64 + x86_64 合并成单个通用二进制，兼容所有 Mac
#   arm64            = 仅 Apple Silicon 原生二进制，体积更小
#   x86_64           = 仅 Intel 原生二进制，体积更小
ARCH="${ARCH:-universal}"
case "${ARCH}" in
  universal)
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    DMG_SUFFIX=""
    VOLNAME="BigDaddy Installer"
    ;;
  arm64)
    ARCH_FLAGS=(--arch arm64)
    DMG_SUFFIX="-arm64"
    VOLNAME="BigDaddy Installer (Apple Silicon)"
    ;;
  x86_64)
    ARCH_FLAGS=(--arch x86_64)
    DMG_SUFFIX="-x86_64"
    VOLNAME="BigDaddy Installer (Intel)"
    ;;
  *)
    echo "Unknown ARCH '${ARCH}' (expected universal|arm64|x86_64)" >&2
    exit 1
    ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${ROOT_DIR}/BigDaddy/Info.plist")
BUILD_NUMBER=$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null || echo "1")
echo "Building BigDaddy version ${VERSION} (Build ${BUILD_NUMBER}, arch=${ARCH})..."

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${DIST_DIR}"

swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}" --show-bin-path)

cp "${BIN_DIR}/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"

# 临时向打包的 Info.plist 写入构建号和生产 API 地址，代码库中的源文件保持不变
# （源文件里的 localhost:8009 只用于本地 `swift run` 开发调试）
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BigDaddyAPIBaseURL ${BIGDADDY_API_BASE_URL:-https://proxy-ko.bigdaddy.mom/api/v1}" "${APP_DIR}/Contents/Info.plist"

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  codesign --force --sign "-" "${APP_DIR}"
else
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

mkdir -p "${STAGING_DIR}"
cp -R "${APP_DIR}" "${STAGING_DIR}/BigDaddy.app"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${DIST_DIR}/BigDaddy-v${VERSION}${DMG_SUFFIX}.dmg"

hdiutil create \
  -srcfolder "${STAGING_DIR}" \
  -volname "${VOLNAME}" \
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
