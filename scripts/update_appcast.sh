#!/usr/bin/env bash
# 把一个新版本条目插入 Sparkle appcast.xml（不存在则从模板新建）。
# 用法见 .github/workflows/release.yml 里的调用方式，所有参数都通过环境变量传入：
#   APPCAST_PATH, VERSION, BUILD_NUMBER, MIN_OS, DMG_URL, EDSIGNATURE, DMG_LENGTH,
#   RELEASE_NOTES_URL
set -euo pipefail

: "${APPCAST_PATH:?}" "${VERSION:?}" "${BUILD_NUMBER:?}" "${MIN_OS:?}" \
  "${DMG_URL:?}" "${EDSIGNATURE:?}" "${DMG_LENGTH:?}" "${RELEASE_NOTES_URL:?}"

if [[ ! -f "${APPCAST_PATH}" ]]; then
  cat > "${APPCAST_PATH}" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>BigDaddy Updates</title>
    <link>https://beautare.github.io/big-daddy-macOS/appcast.xml</link>
    <description>BigDaddy for macOS release feed</description>
    <language>zh</language>
    <!-- ITEMS -->
  </channel>
</rss>
EOF
fi

PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM_FILE=$(mktemp)
cat > "${ITEM_FILE}" <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <description><![CDATA[<p><a href="${RELEASE_NOTES_URL}">View release notes on GitHub</a></p>]]></description>
      <enclosure url="${DMG_URL}" sparkle:edSignature="${EDSIGNATURE}" length="${DMG_LENGTH}" type="application/octet-stream" />
    </item>
EOF

# 插入到 <!-- ITEMS --> 标记之后，最新版本始终排在最前面
sed -i '' -e "/<!-- ITEMS -->/r ${ITEM_FILE}" "${APPCAST_PATH}"
rm -f "${ITEM_FILE}"

echo "Updated ${APPCAST_PATH} with version ${VERSION} (build ${BUILD_NUMBER})"
