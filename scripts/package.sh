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

cp "${BIN_DIR}/BigDaddy" "${APP_DIR}/Contents/MacOS/BigDaddy"
cp "${ROOT_DIR}/BigDaddy/Info.plist" "${APP_DIR}/Contents/Info.plist"
# 应用图标（由 scripts/generate_appicon.swift 生成后提交进仓库）
cp "${ROOT_DIR}/BigDaddy/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
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
  codesign --force --deep --sign "-" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "-" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
else
  codesign --force --deep --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" --entitlements "${ROOT_DIR}/entitlements.plist" "${APP_DIR}"
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
