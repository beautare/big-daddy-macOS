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

# 版本号单一来源：优先显式传入的 VERSION，其次最近的 git tag（去掉 v 前缀），
# 都没有时才退回仓库 Info.plist 里的占位值（例如无 tag 的全新 checkout）
VERSION="${VERSION:-$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
if [[ -z "${VERSION}" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${ROOT_DIR}/BigDaddy/Info.plist")
fi
BUILD_NUMBER=$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null || echo "1")
echo "Building BigDaddy version ${VERSION} (Build ${BUILD_NUMBER}, arch=${ARCH})..."

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks" "${DIST_DIR}"

swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}" --show-bin-path)

cp "${BIN_DIR}/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"
# 应用图标（由 scripts/generate_appicon.swift 生成后提交进仓库）
cp "${ROOT_DIR}/BigDaddy/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 嵌入 Sparkle.framework（动态框架必须放在 Contents/Frameworks/ 下，@rpath 才能找到）
SPARKLE_FW="${BIN_DIR}/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
  cp -R "${SPARKLE_FW}" "${APP_DIR}/Contents/Frameworks/"
else
  echo "ERROR: Sparkle.framework not found at ${SPARKLE_FW}" >&2
  exit 1
fi

# 修正 rpath：SPM 构建的二进制默认 rpath 指向构建目录，
# 独立 .app 需要指向 Contents/Frameworks/
install_name_tool -add_rpath @executable_path/../Frameworks "${APP_DIR}/Contents/MacOS/BigDaddy" 2>/dev/null || true

# 临时向打包的 Info.plist 写入版本号、构建号和生产 API 地址，代码库中的源文件保持不变
# （源文件里的 localhost:8009 只用于本地 `swift run` 开发调试）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BigDaddyAPIBaseURL ${BIGDADDY_API_BASE_URL:-https://proxy-ko.bigdaddy.mom/api/v1}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BigDaddyDashboardBaseURL ${BIGDADDY_DASHBOARD_BASE_URL:-https://dashboard.bigdaddy.mom}" "${APP_DIR}/Contents/Info.plist"

# 签名顺序：先签内嵌的 framework（含其内部 XPC Services），再签外层 app bundle
if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  codesign --force --deep --sign "-" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "-" "${APP_DIR}"
else
  codesign --force --deep --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

mkdir -p "${STAGING_DIR}"
cp -R "${APP_DIR}" "${STAGING_DIR}/BigDaddy.app"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${DIST_DIR}/BigDaddy-v${VERSION}${DMG_SUFFIX}.dmg"

# hdiutil create 在 CI 上偶发 "Resource busy"：codesign 刚签完名的 .app 会被 Spotlight
# (mds/mdworker) 短暂加锁索引，hdiutil 这时候去读同一批文件就会撞上——纯时序竞争，不是
# 确定性 bug，重试几次通常就能过。universal 架构因为要同时打包 arm64+x86_64、体积更大、
# 拷贝签名耗时更长，撞上这个窗口的概率也更高，实测确认过重试有效。
hdiutil_create_with_retry() {
  local max_attempts=5
  local delay=5
  local attempt=1
  while true; do
    rm -f "${DMG_PATH}" # 失败的尝试可能留下部分写入的文件，重试前清掉避免 "File exists"
    if hdiutil create \
      -srcfolder "${STAGING_DIR}" \
      -volname "${VOLNAME}" \
      -fs HFS+ \
      -fsargs "-c c=64,a=16,e=16" \
      -format UDZO \
      "${DMG_PATH}"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      echo "hdiutil create failed after ${max_attempts} attempts" >&2
      return 1
    fi
    echo "hdiutil create failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..." >&2
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
}

hdiutil_create_with_retry

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
