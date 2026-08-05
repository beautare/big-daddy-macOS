#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/Release/BigDaddy.app"
FILTER_DERIVED_DATA="${BUILD_DIR}/FilterDerivedData"
FILTER_EXTENSION_BUNDLE_IDENTIFIER="vip.bigdaddy.monitor.web-filter-extension"
FILTER_EXTENSION_NAME="${FILTER_EXTENSION_BUNDLE_IDENTIFIER}.systemextension"
FILTER_EXTENSION_BUILD_PATH="${FILTER_DERIVED_DATA}/Build/Products/Release/${FILTER_EXTENSION_NAME}"
FILTER_EXTENSION_APP_PATH="${APP_DIR}/Contents/Library/SystemExtensions/${FILTER_EXTENSION_NAME}"
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
    XCODE_ARCHS="arm64 x86_64"
    DMG_SUFFIX=""
    VOLNAME="BigDaddy Installer"
    ;;
  arm64)
    ARCH_FLAGS=(--arch arm64)
    XCODE_ARCHS="arm64"
    DMG_SUFFIX="-arm64"
    VOLNAME="BigDaddy Installer (Apple Silicon)"
    ;;
  x86_64)
    ARCH_FLAGS=(--arch x86_64)
    XCODE_ARCHS="x86_64"
    DMG_SUFFIX="-x86_64"
    VOLNAME="BigDaddy Installer (Intel)"
    ;;
  *)
    echo "Unknown ARCH '${ARCH}' (expected universal|arm64|x86_64)" >&2
    exit 1
    ;;
esac

# 版本号单一来源：优先显式传入的 VERSION，其次当前提交可达的最高版本 tag（去掉 v 前缀），
# 都没有时才退回仓库 Info.plist 里的占位值（例如无 tag 的全新 checkout）。按版本排序可避免
# 同一个提交同时存在多个 tag 时，git describe 任意选中较旧版本。
VERSION="${VERSION:-$(git -C "${ROOT_DIR}" tag --merged HEAD --list 'v[0-9]*' --sort=-v:refname | sed -n '1{s/^v//;p;}')}"
if [[ -z "${VERSION}" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${ROOT_DIR}/BigDaddy/Info.plist")
fi
# 构建号从版本号派生成一个不含句点的扁平整数：MAJOR*1000000 + MINOR*1000 + PATCH，
# 不再用 git rev-list --count HEAD 数提交数。
#
# 换掉 git 计数的原因：v0.10.4 和 v0.10.5 两个 tag 曾经被打在同一个 commit 上，
# rev-list --count 对两者算出同一个值（81），appcast 里这两条 item 的 sparkle:version
# 因此相同——Sparkle 靠这个字段判断"有没有更新"，判成了"没有"，装着 0.10.4 的用户从此
# 收不到 0.10.5 的提示，没有任何报错，线上 appcast.xml 里这条坏记录留到现在才被发现。
#
# 没有直接拿 VERSION 字符串本身（"0.11.0"）当构建号，是因为验证过行不通：Sparkle 的
# SUStandardVersionComparator 按句点拆成 ["0",".","11",".","0"] 逐段比较，第一段"0"
# 跟线上现存的纯数字旧构建号（比如"81"）比时，0 < 81，新版本反而被判成"比已装的旧版本
# 还旧"——所有存量安装在这次切换后会再也收不到任何更新提示，比原来的 bug 更隐蔽也更
# 严重。扁平整数没有句点，跟"81"一样只有一段，直接按数值比大小：11000 > 81。
#
# MINOR/PATCH 留了三位数（0~999）的余量，按这个项目的发版节奏（当前 MINOR=11、单个
# MINOR 下最多发过 6 个 PATCH）近乎不可能触顶；真触顶了也只是构建号不再精确对应版本号，
# 不会重新引入"构建号撞车"这个当前在修的 bug。
IFS='.' read -r _VER_MAJOR _VER_MINOR _VER_PATCH <<< "${VERSION}"
BUILD_NUMBER=$((_VER_MAJOR * 1000000 + _VER_MINOR * 1000 + _VER_PATCH))
echo "Building BigDaddy version ${VERSION} (Build ${BUILD_NUMBER}, arch=${ARCH})..."

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks" "${DIST_DIR}"

swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build --package-path "${ROOT_DIR}" -c release "${ARCH_FLAGS[@]}" --show-bin-path)

xcodebuild \
  -project "${ROOT_DIR}/BigDaddyFilterExtension.xcodeproj" \
  -scheme BigDaddyWebFilter \
  -configuration Release \
  -derivedDataPath "${FILTER_DERIVED_DATA}" \
  -destination "generic/platform=macOS" \
  ARCHS="${XCODE_ARCHS}" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

cp "${BIN_DIR}/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"
# 应用图标（由 scripts/generate_appicon.swift 生成后提交进仓库）
cp "${ROOT_DIR}/BigDaddy/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
mkdir -p "${APP_DIR}/Contents/Library/SystemExtensions"
cp -R "${FILTER_EXTENSION_BUILD_PATH}" "${FILTER_EXTENSION_APP_PATH}"
# 系统权限说明走 InfoPlist.strings：中文环境统一显示简体，其他语言回退英文。
for LOCALIZATION in Base.lproj zh_CN.lproj zh_HK.lproj zh_TW.lproj; do
  cp -R "${ROOT_DIR}/BigDaddy/${LOCALIZATION}" "${APP_DIR}/Contents/Resources/${LOCALIZATION}"
done

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

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  TEAM_IDENTIFIER_PREFIX=""
else
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for Network Extension signing}"
  : "${BIGDADDY_APP_PROVISIONING_PROFILE:?BIGDADDY_APP_PROVISIONING_PROFILE is required for Network Extension signing}"
  : "${BIGDADDY_FILTER_PROVISIONING_PROFILE:?BIGDADDY_FILTER_PROVISIONING_PROFILE is required for Network Extension signing}"
  TEAM_IDENTIFIER_PREFIX="${APPLE_TEAM_ID}."
  cp "${BIGDADDY_APP_PROVISIONING_PROFILE}" "${APP_DIR}/Contents/embedded.provisionprofile"
  cp "${BIGDADDY_FILTER_PROVISIONING_PROFILE}" "${FILTER_EXTENSION_APP_PATH}/Contents/embedded.provisionprofile"
fi

APP_GROUP_IDENTIFIER="${TEAM_IDENTIFIER_PREFIX}group.vip.bigdaddy.shared"
FILTER_MACH_SERVICE_NAME="${APP_GROUP_IDENTIFIER}.BigDaddyWebFilter"
/usr/libexec/PlistBuddy -c "Set :BigDaddyAppGroupIdentifier ${APP_GROUP_IDENTIFIER}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BigDaddyAppGroupIdentifier ${APP_GROUP_IDENTIFIER}" "${FILTER_EXTENSION_APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NetworkExtension:NEMachServiceName ${FILTER_MACH_SERVICE_NAME}" "${FILTER_EXTENSION_APP_PATH}/Contents/Info.plist"

FILTER_BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${FILTER_EXTENSION_APP_PATH}/Contents/Info.plist")
FILTER_EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${FILTER_EXTENSION_APP_PATH}/Contents/Info.plist")
FILTER_RESOLVED_MACH_SERVICE_NAME=$(/usr/libexec/PlistBuddy -c "Print :NetworkExtension:NEMachServiceName" "${FILTER_EXTENSION_APP_PATH}/Contents/Info.plist")
if [[ "${FILTER_EXTENSION_NAME}" != "${FILTER_BUNDLE_IDENTIFIER}.systemextension" || "${FILTER_EXECUTABLE}" != "${FILTER_BUNDLE_IDENTIFIER}" ]]; then
  echo "ERROR: system extension service path must match its bundle identifier" >&2
  echo "       wrapper=${FILTER_EXTENSION_NAME}, executable=${FILTER_EXECUTABLE}, bundle=${FILTER_BUNDLE_IDENTIFIER}" >&2
  exit 1
fi
if [[ "${FILTER_RESOLVED_MACH_SERVICE_NAME}" != "${APP_GROUP_IDENTIFIER}."* ]]; then
  echo "ERROR: NEMachServiceName must use an entitled app group as its prefix" >&2
  echo "       mach-service=${FILTER_RESOLVED_MACH_SERVICE_NAME}, app-group=${APP_GROUP_IDENTIFIER}" >&2
  exit 1
fi

HOST_ENTITLEMENTS="${BUILD_DIR}/resolved-host.entitlements"
FILTER_ENTITLEMENTS="${BUILD_DIR}/resolved-filter.entitlements"
cp "${ROOT_DIR}/entitlements.plist" "${HOST_ENTITLEMENTS}"
cp "${ROOT_DIR}/BigDaddyFilterExtension/BigDaddyFilterExtension.entitlements" "${FILTER_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 ${APP_GROUP_IDENTIFIER}" "${HOST_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 ${APP_GROUP_IDENTIFIER}" "${FILTER_ENTITLEMENTS}"

if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  HOST_PROFILE_PLIST="${BUILD_DIR}/host-profile.plist"
  FILTER_PROFILE_PLIST="${BUILD_DIR}/filter-profile.plist"
  security cms -D -i "${BIGDADDY_APP_PROVISIONING_PROFILE}" > "${HOST_PROFILE_PLIST}"
  security cms -D -i "${BIGDADDY_FILTER_PROVISIONING_PROFILE}" > "${FILTER_PROFILE_PLIST}"

  inject_profile_identity() {
    local profile_plist="$1"
    local entitlements_plist="$2"
    local application_identifier
    local team_identifier
    local keychain_access_group
    application_identifier=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "${profile_plist}")
    team_identifier=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "${profile_plist}")
    keychain_access_group=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups:0" "${profile_plist}")
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${application_identifier}" "${entitlements_plist}"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${team_identifier}" "${entitlements_plist}"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "${entitlements_plist}"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${keychain_access_group}" "${entitlements_plist}"
  }

  inject_profile_identity "${HOST_PROFILE_PLIST}" "${HOST_ENTITLEMENTS}"
  inject_profile_identity "${FILTER_PROFILE_PLIST}" "${FILTER_ENTITLEMENTS}"
fi

# 签名顺序：先签内嵌的 framework（含其内部 XPC Services），再签外层 app bundle
#
# --options runtime（Hardened Runtime）是公证的硬性要求，同时它会**默认禁止本 App 发送
# Apple Event**——除非 entitlements.plist 里带着 com.apple.security.automation.apple-events。
# 缺了那一条的表现极具迷惑性：读浏览器网址的 NSAppleScript 每次都立刻收到 -1743，系统连
# 授权询问框都不弹，「隐私与安全性 → 自动化」里也永远不会出现 BigDaddy，而本地 swift run
# （ad-hoc 签名、没有 Hardened Runtime）却一切正常。改这个文件时别把那一条删掉。
#
# 另注：entitlements.plist 里**不能写 XML 注释**。codesign 会把它交给 AMFI 的严格解析器，
# 遇到注释直接 "AMFIUnserializeXML: syntax error" 整个打包失败，所以说明都写在这里。
if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  codesign --force --sign "-" --entitlements "${FILTER_ENTITLEMENTS}" "${FILTER_EXTENSION_APP_PATH}"
  codesign --force --deep --sign "-" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "-" --entitlements "${HOST_ENTITLEMENTS}" "${APP_DIR}"
else
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${FILTER_ENTITLEMENTS}" "${FILTER_EXTENSION_APP_PATH}"
  codesign --force --deep --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${HOST_ENTITLEMENTS}" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

# 签完立刻回读一次：这条 entitlement 一旦丢失，症状要等到用户装上正式版、家长在仪表盘上
# 看到"网址未授权"才暴露，代价太高。构建期一行断言就能挡住。
#
# 直接在原始 XML 上做子串匹配，不经过 plutil -p 转成人类可读格式再解析——`codesign -d
# --entitlements - --xml` 吐出来的是不带换行的单行 XML，plutil -p 对布尔值的文本渲染
# （"true" 还是 "1"）因 macOS 版本而异，本地机器上验证通过的写法在 CI 的 macos-14 跑者
# 上出现过误报（entitlement 明明签进去了，断言却说缺失）。XML 里 <true/> 这个字面量是
# DTD 定死的，不随 macOS 版本变化，tr 去掉换行只是为了让子串匹配不必关心格式化风格。
ENTITLEMENTS_XML=$(codesign -d --entitlements - --xml "${APP_DIR}" 2>/dev/null | tr -d '\n')
if [[ "${ENTITLEMENTS_XML}" != *"<key>com.apple.security.automation.apple-events</key><true/>"* ]]; then
  echo "ERROR: com.apple.security.automation.apple-events missing from the signed app;" >&2
  echo "       browser URL capture would silently fail in the released build." >&2
  exit 1
fi
if [[ "${ENTITLEMENTS_XML}" != *"<key>com.apple.developer.system-extension.install</key><true/>"* ]]; then
  echo "ERROR: com.apple.developer.system-extension.install missing from the signed app" >&2
  exit 1
fi
FILTER_ENTITLEMENTS_XML=$(codesign -d --entitlements - --xml "${FILTER_EXTENSION_APP_PATH}" 2>/dev/null | tr -d '\n')
if [[ "${FILTER_ENTITLEMENTS_XML}" != *"<string>content-filter-provider-systemextension</string>"* ]]; then
  echo "ERROR: content-filter-provider-systemextension entitlement missing from the signed system extension" >&2
  exit 1
fi

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
