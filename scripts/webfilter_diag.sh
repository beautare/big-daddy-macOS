#!/usr/bin/env bash
set -euo pipefail

# 网站访问限制的现场诊断工具。
#
# 存在的理由：这个功能的每一次迭代都栽在同一个坑里——**改了代码，但真正在跑的不是这份
# 代码**。系统扩展由 systemextensionsd 独立管理，装一个新 .app 并不等于换掉已激活的那份
# 扩展；而扩展跑不跑得对，从主 App 这边完全看不出来。于是"测了没效果"永远有两种解释：
# 代码不对，或者代码根本没上去。靠回忆分不清，只能靠机器验。
#
#   verify   回答"此刻真正在跑的是哪份代码"：已激活的扩展版本、它的二进制里有没有本轮
#            的诊断标记、进程在不在、.app 里那份和已激活那份是否同一个版本。
#   capture  抓一次限制生效的完整现场：扩展进程 + 主 App + nesessionmanager 三方日志，
#            外加主 App 的审计日志，最后按时间轴把决定性的几行摘出来。
#
# 典型用法：
#   ./scripts/webfilter_diag.sh verify
#   ./scripts/webfilter_diag.sh capture        # 开始抓，去家长端开限制，回来按 Ctrl-C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER_EXTENSION_BUNDLE_IDENTIFIER="vip.bigdaddy.monitor.web-filter-extension"
FILTER_EXTENSION_NAME="${FILTER_EXTENSION_BUNDLE_IDENTIFIER}.systemextension"
SYSTEM_EXTENSIONS_DIR="/Library/SystemExtensions"
INSTALLED_APP="${INSTALLED_APP:-/Applications/BigDaddy.app}"
AUDIT_LOG="${HOME}/Library/Application Support/BigDaddy/guardian-audit.log"

# 本轮诊断日志的标记串。改 FilterDataProvider 里那行 NSLog 的话，这里要跟着改——
# 它是"已激活的二进制到底含不含这轮代码"唯一的判据。
#
# 教训：这里曾经写着 "applied policy source="，而回滚推送通道时那行日志的字段变了，
# 脚本没跟着改，于是对一份**完全正确**的构建报出"代码没上去"。所以只取那行日志里最
# 稳定的那一小截，别把随时会调整的字段名写进来。
DIAGNOSTIC_MARKER="applied policy revision="

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
bad()  { echo "${RED}✗${RESET} $*"; }
head_() { echo; echo "${BOLD}$*${RESET}"; }

# 已激活（enabled + active）的那一行，形如：
#   *   *   L2GSNW7RA2   vip.bigdaddy...(0.16.6/16006)   name   [activated enabled]
# 前两列的 * 分别是 enabled 和 active，只有两个都打星的才是此刻真正在用的那份。
activated_extension_version() {
  systemextensionsctl list 2>/dev/null \
    | awk -v id="${FILTER_EXTENSION_BUNDLE_IDENTIFIER}" '
        $1 == "*" && $2 == "*" && index($0, id) > 0 {
          if (match($0, /\([0-9][^)]*\)/)) {
            v = substr($0, RSTART + 1, RLENGTH - 2)
            split(v, parts, "/")
            print parts[1]
            exit
          }
        }'
}

# 已激活扩展的 bundle 路径。/Library/SystemExtensions/<UUID>/ 下会堆着历次装过的版本
# （旧的停在 "waiting to uninstall on reboot"），只能靠 Info.plist 里的版本号认出哪个
# 才是此刻激活的那份——不能拿"最新修改的目录"当答案。
activated_extension_bundle() {
  local want="$1" bundle plist version
  for bundle in "${SYSTEM_EXTENSIONS_DIR}"/*/"${FILTER_EXTENSION_NAME}"; do
    [[ -d "${bundle}" ]] || continue
    plist="${bundle}/Contents/Info.plist"
    [[ -f "${plist}" ]] || continue
    version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${plist}" 2>/dev/null || true)"
    if [[ "${version}" == "${want}" ]]; then
      echo "${bundle}"
      return 0
    fi
  done
  return 1
}

binary_has_marker() {
  local binary="$1"
  [[ -f "${binary}" ]] || return 1
  strings -a "${binary}" 2>/dev/null | grep -q -- "${DIAGNOSTIC_MARKER}"
}

cmd_verify() {
  local exit_code=0

  head_ "已激活的系统扩展"
  local activated
  activated="$(activated_extension_version || true)"
  if [[ -z "${activated}" ]]; then
    bad "没有任何一份 ${FILTER_EXTENSION_BUNDLE_IDENTIFIER} 处于 [activated enabled]"
    echo "  → 网站访问限制此刻不可能在工作。先在「系统设置 → 通用 → 登录项与扩展 →"
    echo "    网络扩展」里确认它没被关掉，再重装一次 .app。"
    return 1
  fi
  ok "版本 ${activated}"

  local bundle binary
  if ! bundle="$(activated_extension_bundle "${activated}")"; then
    bad "在 ${SYSTEM_EXTENSIONS_DIR} 下找不到版本 ${activated} 的 bundle"
    return 1
  fi
  echo "  路径 ${bundle}"

  head_ "已激活的二进制里有没有本轮代码"
  binary="${bundle}/Contents/MacOS/${FILTER_EXTENSION_BUNDLE_IDENTIFIER}"
  if binary_has_marker "${binary}"; then
    ok "含诊断标记「${DIAGNOSTIC_MARKER}」——正在跑的确实是本轮的扩展代码"
  else
    bad "不含诊断标记「${DIAGNOSTIC_MARKER}」"
    echo "  → 你改的代码没有上到这份扩展上。任何测试结论在此之前都不成立。"
    echo "  → 重新打包时**必须抬版本号**：macOS 对已激活的系统扩展是按版本决定要不要"
    echo "    替换的，版本没变它就继续用旧的，哪怕 .app 里的二进制已经换了。"
    exit_code=1
  fi

  head_ "扩展进程"
  local pid cpu started
  pid="$(pgrep -f "${FILTER_EXTENSION_BUNDLE_IDENTIFIER}" 2>/dev/null | head -1 || true)"
  if [[ -n "${pid}" ]]; then
    cpu="$(ps -p "${pid}" -o time= 2>/dev/null | tr -d ' ')"
    started="$(ps -p "${pid}" -o lstart= 2>/dev/null | sed 's/^ *//')"
    ok "在跑（pid ${pid}，启动于 ${started}，已用 CPU ${cpu}）"
    # CPU 时间是"它到底有没有在真干活"的旁证：过滤器常开之后，全机每条连接都要过
    # handleNewFlow、还要 peek 握手包找 SNI，跑几个小时必然累积出可观的 CPU。接近 0
    # 反而说明它虽然起来了却没在过滤。
    if [[ "${cpu}" == "0:00.00" ]]; then
      warn "CPU 时间几乎为 0——进程起来了，但看不出它在过滤任何流量"
    fi

    # 关键一致性检查：二进制比进程还新 = 你重装过，但系统没重启这个 provider，
    # 于是磁盘上是新代码、内存里跑的是旧代码。这种情况下连 strings 检查都会骗你。
    # 版本号复用（同一个 VERSION 打两次包）最容易踩到这个坑。
    local bin_mtime proc_start
    bin_mtime="$(stat -f %m "${binary}" 2>/dev/null || echo 0)"
    proc_start="$(ps -p "${pid}" -o lstart= 2>/dev/null | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null || echo 0)"
    if [[ "${bin_mtime}" -gt 0 && "${proc_start}" -gt 0 && "${bin_mtime}" -gt "${proc_start}" ]]; then
      bad "磁盘上的二进制比进程还新——内存里跑的是旧代码"
      echo "  → 重装时复用了同一个版本号，系统换了文件却没重启 provider。"
      echo "  → 抬版本号重打包，或重启这台 Mac。"
      exit_code=1
    else
      ok "进程启动晚于二进制落盘——内存里跑的就是这份代码"
    fi
  else
    warn "没在跑"
    echo "  → 只有家长打开过网站限制、或设备已绑定使过滤常开时它才会被系统拉起来。"
    echo "    如果限制明明开着它却不在，那就是它起不来（看崩溃报告）。"
  fi

  head_ ".app 里那份 vs 已激活那份"
  local app_plist app_version
  app_plist="${INSTALLED_APP}/Contents/Library/SystemExtensions/${FILTER_EXTENSION_NAME}/Contents/Info.plist"
  if [[ -f "${app_plist}" ]]; then
    app_version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${app_plist}" 2>/dev/null || echo "?")"
    if [[ "${app_version}" == "${activated}" ]]; then
      ok "都是 ${activated}"
    else
      bad "${INSTALLED_APP} 里是 ${app_version}，已激活的却是 ${activated}"
      echo "  → 装了新 .app 但系统没换扩展。抬版本号重打包，或重启后再试。"
      exit_code=1
    fi
  else
    warn "${INSTALLED_APP} 里没找到内嵌扩展（是不是没装到 /Applications？）"
    echo "  → 可用 INSTALLED_APP=/path/to/BigDaddy.app 指定"
  fi

  return "${exit_code}"
}

cmd_capture() {
  local stamp out_dir log_file audit_before
  stamp="$(date +%Y%m%d-%H%M%S)"
  out_dir="${TMPDIR:-/tmp}/bigdaddy-webfilter-${stamp}"
  mkdir -p "${out_dir}"
  log_file="${out_dir}/unified.log"
  audit_before="${out_dir}/audit-before.log"

  echo "${BOLD}先确认在跑的是哪份代码${RESET}"
  if ! cmd_verify; then
    echo
    bad "上面的检查没过——现在抓日志得到的结论不可信。建议先解决再抓。"
    echo "  仍要继续请按回车，放弃按 Ctrl-C。"
    read -r _
  fi

  cp "${AUDIT_LOG}" "${audit_before}" 2>/dev/null || : > "${audit_before}"

  head_ "开始采集"
  echo "输出目录 ${out_dir}"
  echo
  echo "现在去做这几步（顺序很重要）："
  echo "  1. ${BOLD}彻底退出 Chrome${RESET}（⌘Q，不是关窗口）——它已经开着的连接早于扩展启动的话，"
  echo "     对过滤器不可见，你测到的会是另一个问题。"
  echo "  2. 重开 Chrome，打开那个受限网站，确认能正常访问。"
  echo "  3. 去家长端打开网站限制（或触发限网窗口）。"
  echo "  4. 在 Chrome 里 ⌘R、再开个新标签试试。"
  echo "  5. ${BOLD}继续等，至少 5 分钟${RESET}，直到 Chrome 真的访问不了为止。"
  echo "  6. 回到这里按 ${BOLD}Ctrl-C${RESET} 结束采集。"
  echo
  # 第 5 步不是客套。要量的就是"延迟有多久"，而慢的那条路径本身就是分钟级的：采集窗口
  # 短于故障时长的话，日志里只会留下一段什么都没发生的空白，看起来像"扩展根本没日志"，
  # 其实只是还没轮到它。之前一次 13 秒的采集就栽在这里。
  echo "  （别提前结束：要量的就是延迟本身，窗口必须盖住整个等待过程。）"
  echo

  # 三方都要：扩展进程（判定与掐断）、主 App（决定与推送）、nesessionmanager（系统把
  # 配置分发到哪一步了）。少任何一方都会在时间轴上留下一段解释不了的空白。
  local predicate
  predicate='processImagePath CONTAINS "web-filter-extension"'
  predicate+=' OR process == "BigDaddy"'
  predicate+=' OR (process == "nesessionmanager" AND eventMessage CONTAINS "BigDaddy")'

  log stream --info --predicate "${predicate}" > "${log_file}" 2>&1 &
  local log_pid=$!
  trap 'kill "${log_pid}" 2>/dev/null || true' EXIT INT TERM

  # 前台等着，用户按 Ctrl-C 时 trap 收尾
  wait "${log_pid}" 2>/dev/null || true
  trap - EXIT INT TERM
  kill "${log_pid}" 2>/dev/null || true

  echo
  head_ "时间轴"
  summarize "${log_file}" "${audit_before}" "${out_dir}"
  echo
  echo "完整日志：${log_file}"
}

summarize() {
  local log_file="$1" audit_before="$2" out_dir="$3"
  local timeline="${out_dir}/timeline.txt"
  : > "${timeline}"

  # 主 App 侧："客户端什么时候决定要拦的"
  if [[ -f "${AUDIT_LOG}" ]]; then
    diff <(cat "${audit_before}") <(cat "${AUDIT_LOG}") 2>/dev/null \
      | sed -n 's/^> //p' \
      | grep -E "WEB_FILTER" >> "${timeline}" || true
  fi

  # 扩展侧：策略落地与掐断
  grep -E "applied policy|ignored stale|refusing policy push|declined pushed|provider unreachable" \
    "${log_file}" >> "${timeline}" 2>/dev/null || true

  if [[ ! -s "${timeline}" ]]; then
    bad "没抓到任何关键事件。"
    echo "  → 家长端那次操作可能压根没送达这台 Mac（配置轮询 60s / 命令轮询 30s），"
    echo "    也可能扩展没在跑。先看 ${log_file} 里有没有主 App 的动静。"
    return
  fi

  sort "${timeline}" | sed 's/^/  /'

  echo
  head_ "怎么读"
  # 注意别写成 `grep -c ... || echo 0`：grep 没匹配到时**既打印 0 又返回 1**，那个 || 会
  # 再补一个 0，变量里就成了 "0\n0"，后面的 [[ ]] 数值比较直接语法错误。用 || true。
  local pushed applied_system dropped_zero quic_blind
  pushed="$(grep -c "source=push" "${log_file}" 2>/dev/null || true)"; pushed="${pushed:-0}"
  applied_system="$(grep -c "source=systemConfiguration" "${log_file}" 2>/dev/null || true)"; applied_system="${applied_system:-0}"
  dropped_zero="$(grep -c "dropped=0" "${log_file}" 2>/dev/null || true)"; dropped_zero="${dropped_zero:-0}"
  # 跟踪表里有 UDP 流、认出来的 QUIC 却是 0 —— 远端端点取不到值，HTTP/3 整个绕过了限制。
  quic_blind="$(grep -E "udp=[1-9][0-9]* quic=0" "${log_file}" 2>/dev/null | grep -c . || true)"; quic_blind="${quic_blind:-0}"

  if [[ "${quic_blind}" -gt 0 ]]; then
    bad "有 UDP 流但一条 QUIC 都没认出来（udp>0 而 quic=0）"
    echo "  → 远端端点 API 取不到值，isLikelyQUIC 恒为 false，HTTP/3 完全绕过了域名黑名单。"
    echo "  → 表现就是「有的域名秒拦、youtube 这类默认走 HTTP/3 的怎么都拦不住」。"
    echo
  fi

  if [[ "${pushed}" -eq 0 && "${applied_system}" -eq 0 ]]; then
    bad "扩展一次都没应用过策略——它没收到，或者它没在跑。"
  elif [[ "${pushed}" -eq 0 ]]; then
    warn "只有 systemConfiguration，没有 push：加速通道没走通。"
    echo "  看看有没有 refusing/declined/unreachable 那几行——ad-hoc 签名的构建会被"
    echo "  主动拒绝（校验不了调用方就不接受可写指令），那是设计如此。"
  elif [[ "${dropped_zero}" -gt 0 ]]; then
    warn "push 到了，但 dropped=0：那些连接根本不在跟踪表里。"
    echo "  多半是它们早于扩展进程启动（装新版会重启扩展并清空跟踪表）。"
    echo "  重开浏览器再测一次；仍然是 0 的话，问题在覆盖面而不是时效。"
  else
    ok "push 到了、也掐断了流。"
    echo "  如果浏览器**依然**能访问，那就说明 update(_:using:.drop()) 拆不掉已建立的"
    echo "  socket——病根在那一层，加速通道帮不上忙，需要换思路。"
  fi
}

case "${1:-verify}" in
  verify)  cmd_verify ;;
  capture) cmd_capture ;;
  *)
    echo "用法: $0 [verify|capture]" >&2
    exit 2
    ;;
esac
