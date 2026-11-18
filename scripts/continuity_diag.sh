#!/usr/bin/env bash
set -uo pipefail

# 「被关掉后自动重开」（连续性模式 / launchd KeepAlive）现场取证。只读，不改任何东西。
#
# 必须在**孩子那台 Mac 上、用孩子自己的登录账号**、在「终端」里运行：launchd 的 gui 域按
# 用户区分，换个账号或用 ssh 进来都查不到那份 job；统一日志（log show）在 Claude 的沙箱
# 里一行都读不到，只能在本人终端里跑。
#
# 为什么需要它：KeepAlive 本身是可靠的——用与客户端完全相同的 plist 结构
# （KeepAlive = { SuccessfulExit = false }、RunAtLoad、BIGDADDY_LAUNCHED_BY_LAUNCHD）做过
# 端到端复现，进程真崩溃后 launchd 1 秒内拉起、继任者正常存活。所以"开着开关进程还是
# 消失了"只剩三种解释，本脚本逐一取证：
#   1. 消失那一刻进程根本不归 launchd 管（job 没加载 / 被禁用 / 在跑的不是 job 那份进程）；
#   2. 进程以 exit 0 结束（验证码退出、交接、更新、注销被取消……），KeepAlive 按设计不拉；
#   3. launchd 自己把 job 停了（系统设置「允许在后台」被关、launchctl bootout/disable）。
#
# 用法：
#   bash continuity_diag.sh            # 默认看最近 3 天日志、7 天崩溃报告
#   LOG_DAYS=7 bash continuity_diag.sh # 日志多看几天（会慢一些）
# 结果同时写到桌面上的 bigdaddy-continuity-*.txt，把这个文件发回来即可。

# LABEL / PROCESS_NAME / PLIST 只给脚本自测用（拿一份临时 job 走一遍各分支），现场别改。
LABEL="${LABEL:-com.bigdaddy.client}"
PROCESS_NAME="${PROCESS_NAME:-BigDaddy}"
BUNDLE_ID="vip.bigdaddy.monitor"
USER_ID="$(id -u)"
DOMAIN="gui/${USER_ID}"
TARGET="${DOMAIN}/${LABEL}"
PLIST="${PLIST:-${HOME}/Library/LaunchAgents/${LABEL}.plist}"
APP="${INSTALLED_APP:-/Applications/BigDaddy.app}"
AUDIT_LOG="${HOME}/Library/Application Support/BigDaddy/guardian-audit.log"
LOG_DAYS="${LOG_DAYS:-3}"
CRASH_DAYS="${CRASH_DAYS:-7}"
OUT="${OUT:-${HOME}/Desktop/bigdaddy-continuity-$(date +%Y%m%d-%H%M%S).txt}"

exec > >(tee "$OUT") 2>&1

ok()    { echo "  ✓ $*"; }
warn()  { echo "  ! $*"; }
bad()   { echo "  ✗ $*"; }
title() { echo; echo "== $* =="; }

VERDICTS=()
verdict() { VERDICTS+=("$*"); }

title "环境"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "  系统: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "  账号: $(id -un) (uid ${USER_ID})  开机至今: $(uptime | sed 's/.*up \([^,]*\),.*/\1/')"
if [[ -d "$APP" ]]; then
  echo "  已安装: $APP  版本 $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
else
  warn "没找到 ${APP}（装在别处？可用 INSTALLED_APP=/路径/BigDaddy.app 重新运行）"
fi

title "进程"
RUNNING_PIDS="$(pgrep -x "$PROCESS_NAME" || true)"
RUNNING_PID="$(echo "$RUNNING_PIDS" | head -1)"
if [[ -z "$RUNNING_PIDS" ]]; then
  bad "BigDaddy 此刻没有在运行"
else
  ps -o pid=,ppid=,etime=,command= -p "$(echo "$RUNNING_PIDS" | paste -sd, -)" | sed 's/^/  /'
  [[ "$(echo "$RUNNING_PIDS" | wc -l | tr -d ' ')" -gt 1 ]] && warn "同时有多份 BigDaddy 在跑"
  if ps -o command= -p "$RUNNING_PID" | grep -q "/AppTranslocation/"; then
    bad "进程跑在 AppTranslocation 临时路径里：plist 会记下一个重启后就不存在的路径"
    verdict "App 被系统随机化路径（AppTranslocation）运行，launchd 记下的路径重启后失效。把 BigDaddy.app 用访达拖进「应用程序」后再打开一次。"
  fi
fi

title "LaunchAgent plist（${PLIST}）"
PLIST_KEEPALIVE="no"
if [[ -f "$PLIST" ]]; then
  plutil -p "$PLIST" | sed 's/^/  /'
  if [[ "$(plutil -extract KeepAlive.SuccessfulExit raw "$PLIST" 2>/dev/null)" == "false" ]]; then
    PLIST_KEEPALIVE="yes"; ok "plist 里是 KeepAlive = { SuccessfulExit = false }"
  else
    bad "plist 里没有 KeepAlive（连续性没在这台 Mac 上落地，或被本机关闭过）"
  fi
  PROGRAM_PATH="$(plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
  if [[ -n "$PROGRAM_PATH" && ! -x "$PROGRAM_PATH" ]]; then
    bad "plist 指向的程序不存在: ${PROGRAM_PATH}（App 挪过位置或被删除）"
    verdict "plist 指向的可执行文件不存在，launchd 拉不起来。"
  fi
else
  bad "plist 不存在"
fi

title "launchd job（${TARGET}）"
JOB_PRINT="$(launchctl print "$TARGET" 2>&1)"; JOB_RC=$?
JOB_LOADED="no"; JOB_PID=""
if [[ $JOB_RC -eq 0 ]]; then
  JOB_LOADED="yes"
  echo "$JOB_PRINT" | grep -E $'^\t(state|program|pid|runs|last exit code|last terminating signal|spawn type|active count) = ' | sed 's/^\t/  /'
  JOB_PID="$(echo "$JOB_PRINT" | grep -E $'^\tpid = ' | head -1 | sed 's/[^0-9]//g')"
else
  bad "job 没有加载: $(echo "$JOB_PRINT" | head -1)"
fi

DISABLED_LINE="$(launchctl print-disabled "$DOMAIN" 2>/dev/null | grep "\"${LABEL}\"" || true)"
JOB_DISABLED="no"
if [[ -n "$DISABLED_LINE" ]]; then
  echo "  print-disabled: $(echo "$DISABLED_LINE" | tr -s ' \t' ' ')"
  if echo "$DISABLED_LINE" | grep -Eq "=> (disabled|true)"; then JOB_DISABLED="yes"; fi
fi

# 系统设置「允许在后台」的开关。关掉后 launchctl print-disabled 里**看不到**，只能用
# SMAppService.statusForLegacyURL 查（客户端同一个接口）：1=打开 2=被关 0/3=系统没登记。
# 2026-11 那台 Mac 就是 2：登录时 launchd 不加载 agent，每次重启都失联。macOS 12 没这个接口。
BTM_STATUS="$(osascript -l JavaScript -e 'ObjC.import("ServiceManagement"); function run(a){ return $.SMAppService.statusForLegacyURL($.NSURL.fileURLWithPath(a[0])) }' "$PLIST" 2>/dev/null || echo "?")"
JOB_NOT_ALLOWED="no"
case "$BTM_STATUS" in
  1) echo "  「允许在后台」: 打开" ;;
  2) echo "  「允许在后台」: 关闭"; JOB_NOT_ALLOWED="yes" ;;
  *) echo "  「允许在后台」: 查不到（状态码 ${BTM_STATUS}）" ;;
esac

title "判定：此刻 KeepAlive 有没有盯着这份进程"
if [[ "$JOB_DISABLED" == "yes" ]]; then
  bad "job 被 launchctl disable 了：bootstrap 会失败"
  verdict "KeepAlive job 被 launchctl disable：崩溃/被杀都不会拉起，重启后也加载不了。用 launchctl enable ${TARGET} 恢复。"
elif [[ "$JOB_NOT_ALLOWED" == "yes" ]]; then
  bad "系统设置里 BigDaddy 的「允许在后台」被关了：登录时 launchd 不会加载这份 agent（此刻在跑也只是手动打开后客户端自己加载的）"
  verdict "「允许在后台」被关：每次重启后 KeepAlive agent 都不会被加载。0.22.4 及以前的客户端在连续性打开时注销了登录项，于是重启后完全起不来。去「系统设置 → 通用 → 登录项与扩展 → 允许在后台」把 BigDaddy 打开（0.22.4 及以前的客户端写的后台项不叫 BigDaddy，显示成开发者名 Shanghai Jiamei Software Development Co., Ltd）。"
elif [[ "$PLIST_KEEPALIVE" != "yes" ]]; then
  bad "本机没有 KeepAlive plist：连续性没有在这台 Mac 上生效"
  verdict "这台 Mac 上没有 KeepAlive plist。如果 Dashboard 里开关是开着的，看上面审计日志里有没有 CONTINUITY_MODE_TOGGLE state=DISABLED（孩子用验证码在本机关过）。"
elif [[ "$JOB_LOADED" != "yes" ]]; then
  bad "plist 在，但 job 没加载：当前会话里崩溃/被杀不会被拉起"
  verdict "plist 在但 job 没加载（bootstrap 失败或被 bootout），本次登录期间 KeepAlive 不生效。"
elif [[ -z "$RUNNING_PID" ]]; then
  LAST_EXIT="$(echo "$JOB_PRINT" | grep -E $'^\tlast exit code = ' | sed 's/.*= //')"
  LAST_SIG="$(echo "$JOB_PRINT" | grep -E $'^\tlast terminating signal = ' | sed 's/.*= //')"
  if [[ "$LAST_EXIT" == "0" ]]; then
    bad "job 已加载但进程不在，上次以 exit 0 结束：KeepAlive 按设计不会拉起"
    verdict "进程以 exit 0 结束（验证码退出 / 交接 / 更新 / 注销被取消 / 重复实例自退）。用上面审计日志和 launchd 日志对时间点。"
  elif [[ -n "$LAST_SIG" ]]; then
    bad "job 已加载但进程不在，上次死于信号: $LAST_SIG —— 按理 launchd 应已拉起"
    verdict "死于信号但没被拉起：多半是 launchd 自己停的（bootout/disable），看上面 launchd 日志里的 'sent by'。"
  else
    bad "job 已加载但进程不在（last exit code = ${LAST_EXIT:-?}）"
    verdict "job 已加载但进程不在、也没有退出记录：加载后从没被拉起过。看上面 launchd 日志里有没有 spawn 失败。"
  fi
elif [[ -n "$JOB_PID" && "$JOB_PID" == "$RUNNING_PID" ]]; then
  ok "在跑的 BigDaddy（pid ${RUNNING_PID}）就是 launchd job 那份：此刻崩溃/被杀会被拉起"
else
  bad "BigDaddy 在跑（pid ${RUNNING_PID}），但不是 launchd job 那份（job pid=${JOB_PID:-无}）：此刻崩溃/被杀不会被拉起"
  verdict "进程不归 launchd 管（交接没成功）：这段时间里崩溃或被强退就会彻底消失。看审计日志里的 CONTINUITY_MODE_ENABLED / CONTINUITY_HANDOVER_ABORTED。"
fi

title "最近 ${CRASH_DAYS} 天的崩溃报告"
CRASHES="$(find "${HOME}/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
  -maxdepth 2 -iname '*BigDaddy*' -mtime "-${CRASH_DAYS}" 2>/dev/null | sort)"
if [[ -z "$CRASHES" ]]; then
  ok "没有 BigDaddy 的崩溃报告"
else
  verdict "有 $(echo "$CRASHES" | wc -l | tr -d ' ') 份 BigDaddy 崩溃报告（见上），崩溃本身也需要修。"
  while IFS= read -r f; do
    echo "  -- $f"
    osascript -l JavaScript - "$f" <<'JXA' 2>/dev/null || echo "    (解析失败，请把这个文件原样发回)"
function run(argv) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) return "    (读不了)";
  const text = s.js, nl = text.indexOf("\n");
  let header = {}, body = {};
  try { header = JSON.parse(text.slice(0, nl)); } catch (e) {}
  try { body = JSON.parse(text.slice(nl + 1)); } catch (e) { return "    (不是 .ips JSON)"; }
  const out = [];
  out.push("    时间 " + (header.timestamp || body.captureTime || "?") + "  版本 " + (header.app_version || "?"));
  const ex = body.exception || {};
  out.push("    异常 " + [ex.type, ex.signal, ex.subtype, ex.codes].filter(Boolean).join(" | "));
  const term = body.termination || {};
  if (term.indicator || term.namespace) out.push("    终止 " + [term.namespace, term.indicator].filter(Boolean).join(" "));
  if (body.asi) out.push("    附注 " + JSON.stringify(body.asi).slice(0, 300));
  const threads = body.threads || [], images = body.usedImages || [];
  const ft = threads[body.faultingThread] || threads.find(t => t.triggered);
  if (ft && ft.frames) {
    out.push("    崩溃线程 " + body.faultingThread + (ft.queue ? " (" + ft.queue + ")" : ""));
    ft.frames.slice(0, 12).forEach((f, i) => {
      const img = images[f.imageIndex] || {};
      out.push("      " + i + "  " + (img.name || "?") + "  " + (f.symbol || ("+" + f.imageOffset))
        + (f.sourceFile ? "  (" + f.sourceFile + ":" + f.sourceLine + ")" : ""));
    });
  }
  return out.join("\n");
}
JXA
  done <<< "$CRASHES"
fi

title "客户端审计日志（连续性 / 退出 / 关机相关，最近 80 条）"
if [[ -f "$AUDIT_LOG" ]]; then
  grep -E "CONTINUITY_|LAUNCH_AGENT_|LAUNCH_AT_LOGIN_|QUIT_REQUEST_DENIED|PREVIOUS_CRASH_DETECTED|SYSTEM_WILL_POWER_OFF|UPDATE_|DEVICE_(UN)?BOUND|LOG_INITIALIZED" "$AUDIT_LOG" \
    | tail -80 | sed 's/^/  /'
else
  warn "没有审计日志 $AUDIT_LOG"
fi

title "launchd 对这份 job 的记录（最近 ${LOG_DAYS} 天）"
echo "  （读取统一日志，可能要几十秒）"
log show --last "${LOG_DAYS}d" --style compact \
  --predicate "process == \"launchd\" AND eventMessage CONTAINS \"${LABEL}\"" 2>/dev/null \
  | grep -Ei "exit|spawn|signal|sent by|disabl|bootout|bootstrap|load|removing|penalty|throttl|inactive|failed|denied|not allowed|btm" \
  | cut -c1-300 | tail -120 | sed 's/^/  /'

title "谁结束了 BigDaddy（runningboardd，最近 ${LOG_DAYS} 天）"
# runningboardd 会周期性打出整份进程状态快照（里面也含 bundle id 和 exit 字样），用
# RBConnectionClient / RBAssertion 把这类快照排除掉，只留"谁、因为什么结束了它"的单行事件。
log show --last "${LOG_DAYS}d" --style compact \
  --predicate "process == \"runningboardd\" AND eventMessage CONTAINS \"${BUNDLE_ID}\" AND (eventMessage CONTAINS[c] \"terminat\" OR eventMessage CONTAINS[c] \"exited\" OR eventMessage CONTAINS[c] \"kill\") AND NOT eventMessage CONTAINS \"RBConnectionClient\" AND NOT eventMessage CONTAINS \"RBAssertion|\"" 2>/dev/null \
  | grep -i "bigdaddy" | cut -c1-300 | tail -60 | sed 's/^/  /'

title "后台项目管理（系统设置「允许在后台」开关，最近 ${LOG_DAYS} 天）"
log show --last "${LOG_DAYS}d" --style compact \
  --predicate "subsystem == \"com.apple.backgroundtaskmanagement\" AND eventMessage CONTAINS[c] \"bigdaddy\" AND NOT eventMessage CONTAINS \"effectiveItemDisposition\"" 2>/dev/null \
  | cut -c1-300 | tail -40 | sed 's/^/  /'
# effectiveItemDisposition 是客户端自己每分钟查 SMAppService 状态（心跳上报用）留下的，排除。
echo "  （更完整的开关状态需要管理员：sudo sfltool dumpbtm | grep -i -A14 bigdaddy）"

title "关机 / 睡眠 / 唤醒（最近 40 条，不含 DarkWake 与维护性睡眠）"
# 行格式：日期 时间 时区 类型<空格补齐>\t说明。DarkWake、WakeDetails、维护性睡眠每隔几分钟
# 一条，全是噪音；只留真正的合盖/唤醒/关机/开机。
pmset -g log 2>/dev/null \
  | grep -E $'^[0-9-]+ [0-9:]+ [+-][0-9]+ ((Sleep|Wake|Restart) +|(Shutdown|Start)[A-Za-z ]*)\t' \
  | grep -vE "Maintenance Sleep|Sleep Service Back to Sleep" | cut -c1-160 | tail -40 | sed 's/^/  /'

title "开机 / 登录记录（最近 12 条）"
# 拿来对"重启后几点才有人登录"：KeepAlive agent 要等登录进图形会话才会被加载。
last -60 2>/dev/null | grep -E "^(reboot|shutdown)| console " | head -12 | sed 's/^/  /'

title "系统更新记录（最近 6 条）"
# 系统更新的重启常在深夜自动发生，且会重置一些后台项目状态，值得和 SYSTEM_SHUTDOWN 对时间。
softwareupdate --history 2>/dev/null | grep -iE "macOS|Security|Rapid" | tail -6 | sed 's/^/  /'

title "初步结论"
if [[ ${#VERDICTS[@]} -eq 0 ]]; then
  ok "此刻 KeepAlive 正常盯着进程。下次再消失时，请在恢复之前先跑一次本脚本——现场一旦被重新打开就没了。"
else
  for v in "${VERDICTS[@]}"; do echo "  • $v"; done
fi
echo
echo "完整结果已保存到: $OUT"
