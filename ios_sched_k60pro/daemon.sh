#!/system/bin/sh
# =============================================================
# iOS-Style Scheduler 守护进程 - 红米 K60 Pro (socrates)
#
# 三档 QoS 状态机 (对应 iOS 交互分级):
#   触摸档 touch  : 正在触摸 -> top-app uclamp.min=60 (+sched_boost/粒度如有)
#   亮屏档 screen : 亮屏无触摸 -> top-app uclamp.min=25 (前台保底, 看视频/阅读不掉QoS)
#   息屏档 off    : 息屏 -> 全部恢复原值, 阻塞等触摸事件(零开销)
#
# 后台 QoS (对应 iOS 后台饥饿):
#   cpu.idle=1    -> 后台组 SCHED_IDLE, CPU 只要有别人跑就不给后台跑
#   uclamp.max 封顶 -> 后台任务频率天花板
#   cpuset 锁小核 + 权重压制
#
# 所有被修改节点的原始值存档于 /data/adb/ios_sched/defaults,
# 升级/卸载自动还原。
# =============================================================

MODDIR="${0%/*}"
DATA_DIR="/data/adb/ios_sched"
LOG="$DATA_DIR/log.txt"
PID_FILE="$DATA_DIR/daemon.pid"
DEFAULTS_FILE="$DATA_DIR/defaults"

mkdir -p "$DATA_DIR"

# ---------------- 默认配置 ----------------
TOUCH_UCLAMP=60       # 触摸档 top-app uclamp.min %
SCREEN_UCLAMP=25      # 亮屏档 top-app uclamp.min %
IDLE_TIMEOUT=15        # 触摸静止 N 秒后降为亮屏档
SCREEN_POLL=10        # 亮屏档下检查息屏的轮询间隔秒
TOUCH_SCHED_BOOST=2   # 触摸档 sched_boost (内核无节点自动跳过)
TOUCH_MIN_GRAN=1000000
TOUCH_WAKEUP_GRAN=500000
TOUCH_SCHED_LATENCY=8000000
RESTRICT_BG=1
BG_IDLE=1             # 1=后台组 SCHED_IDLE (iOS 后台饥饿)
BG_UCLAMP_MAX=50      # 后台 uclamp.max 封顶 %, 0=不动
BG_GROUPS="background"
BG_WEIGHT_V1=400
BG_WEIGHT_V2=50
BG_CPUS=""
TA_CPUS=""
TS_DEVICE=""

[ -f "$DATA_DIR/config" ] && . "$DATA_DIR/config"

# ---------------- 工具 ----------------

BB="$(command -v busybox 2>/dev/null)"
if [ -z "$BB" ] && [ -x /data/adb/ksu/bin/busybox ]; then
    BB="/data/adb/ksu/bin/busybox"
fi

TO="timeout"
if ! command -v timeout >/dev/null 2>&1; then
    TO="$BB timeout"
    if [ -z "$BB" ]; then
        TO=""
    fi
fi

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
}

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 102400 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

save_default() {
    n="$1"
    [ -e "$n" ] || return 0
    grep -q "^$n|" "$DEFAULTS_FILE" 2>/dev/null && return 0
    echo "$n|$(cat "$n" 2>/dev/null)" >> "$DEFAULTS_FILE"
}

restore_one() {
    n="$1"
    v="$(grep "^$n|" "$DEFAULTS_FILE" 2>/dev/null | head -n 1 | cut -d'|' -f2)"
    [ -n "$v" ] && [ -e "$n" ] && echo "$v" > "$n" 2>/dev/null
}

restore_all() {
    [ -f "$DEFAULTS_FILE" ] || return 0
    while IFS='|' read -r n v; do
        [ -n "$n" ] && [ -e "$n" ] && echo "$v" > "$n" 2>/dev/null
    done < "$DEFAULTS_FILE"
    : > "$DEFAULTS_FILE"
}

wr() {
    [ -e "$1" ] || return 0
    echo "$2" > "$1" 2>/dev/null || log "写入失败: $1"
}

# ---------------- CPU 拓扑 ----------------

detect_topology() {
    ALL_CPUS="$(cat /sys/devices/system/cpu/present 2>/dev/null | head -n 1)"
    [ -n "$ALL_CPUS" ] || ALL_CPUS="0-7"
    min=""
    first=""
    last=""
    for c in /sys/devices/system/cpu/cpu*/cpu_capacity; do
        [ -e "$c" ] || continue
        v="$(cat "$c" 2>/dev/null)"
        [ -n "$v" ] || continue
        if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
    done
    if [ -n "$min" ]; then
        for c in /sys/devices/system/cpu/cpu*/cpu_capacity; do
            if [ "$(cat "$c" 2>/dev/null)" = "$min" ]; then
                id="${c%/cpu_capacity}"
                id="${id##*/cpu}"
                if [ -z "$first" ]; then first="$id"; fi
                last="$id"
            fi
        done
    fi
    [ -n "$first" ] && LITTLE_CPUS="$first-$last" || LITTLE_CPUS="0-2"
}

# ---------------- 亮灭屏检测 ----------------

SCREEN_NODE=""

detect_screen_node() {
    SCREEN_NODE=""
    for f in /sys/class/leds/lcd-backlight/brightness /sys/class/backlight/*/brightness; do
        if [ -e "$f" ]; then
            SCREEN_NODE="$f"
            return 0
        fi
    done
}

# 返回0=亮屏, 1=息屏, 2=未知(按亮屏处理)
screen_on() {
    [ -n "$SCREEN_NODE" ] && detect_screen_node
    if [ -z "$SCREEN_NODE" ]; then
        return 2
    fi
    v="$(cat "$SCREEN_NODE" 2>/dev/null)"
    if [ -n "$v" ]; then
        if [ "$v" -gt 0 ] 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
    return 2
}

# ---------------- 触控输入设备检测 (已验证) ----------------

ts_rank() {
    case "$1" in
        *uinput*|*virtual*) return 0 ;;
    esac
    case "$1" in
        "goodix_ts"|"nt36xxx"|"novatek-ts"|"fts_ts")
            echo 3 ;;
        *oodix*|*ovatek*|*"nt36"*|*"fts"*|*ynapt*)
            echo 2 ;;
        *ouch*|*"xiaomi-touch"*|*"-tp"*|*"tp-"*|*"tp_"*)
            echo 1 ;;
    esac
}

ts_scan_sysfs() {
    best=0
    bestdev=""
    for d in /sys/class/input/input*; do
        [ -e "$d/name" ] || continue
        nm="$(cat "$d/name" 2>/dev/null)"
        r="$(ts_rank "$nm")"
        [ -n "$r" ] || continue
        if [ "$r" -gt "$best" ]; then
            for e in "$d"/event*; do
                if [ -e "$e" ]; then
                    best="$r"
                    bestdev="/dev/input/$(basename "$e")"
                    break
                fi
            done
        fi
    done
    [ -n "$bestdev" ] && echo "$bestdev"
}

ts_scan_proc() {
    [ -s /proc/bus/input/devices ] || return 1
    best=0
    bestdev=""
    name=""
    while IFS= read -r line; do
        case "$line" in
            "N: Name="*)
                name="$line"
                ;;
            "H: Handlers="*)
                r="$(ts_rank "$name")"
                if [ -n "$r" ] && [ "$r" -gt "$best" ]; then
                    for tok in $line; do
                        case "$tok" in
                            event[0-9]*)
                                best="$r"
                                bestdev="/dev/input/$tok"
                                ;;
                        esac
                    done
                fi
                ;;
        esac
    done < /proc/bus/input/devices
    [ -n "$bestdev" ] && echo "$bestdev"
}

ts_scan_getevent() {
    cur=""
    getevent -pl 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            "add device "*" /dev/input/"*)
                cur="${line##*: }"
                ;;
            *"name:"*)
                r="$(ts_rank "$line")"
                if [ -n "$r" ] && [ -n "$cur" ]; then
                    echo "$cur"
                    exit 0
                fi
                ;;
        esac
    done
}

find_ts() {
    if [ -n "$TS_DEVICE" ]; then
        echo "$TS_DEVICE"
        return 0
    fi
    t="$(ts_scan_sysfs)"
    [ -n "$t" ] && { echo "$t"; return 0; }
    t="$(ts_scan_proc)"
    [ -n "$t" ] && { echo "$t"; return 0; }
    t="$(ts_scan_getevent)"
    [ -n "$t" ] && { echo "$t"; return 0; }
    return 1
}

find_ts_valid() {
    t="$(find_ts)"
    if [ -n "$t" ] && [ -e "$t" ]; then
        echo "$t"
    fi
}

ts_name() {
    b="$(basename "$1")"
    for d in /sys/class/input/input*; do
        if [ -e "$d/$b" ]; then
            cat "$d/name" 2>/dev/null
            return 0
        fi
    done
}

# ---------------- 后台持久策略 (iOS 后台饥饿) ----------------

apply_persistent() {
    [ "$RESTRICT_BG" = "1" ] || return 0
    for g in $BG_GROUPS; do
        # cpuset (v1 / v2 都试)
        for f in "/dev/cpuset/$g/cpus" "/dev/cpuctl/$g/cpuset.cpus"; do
            if [ -e "$f" ]; then
                save_default "$f"
                wr "$f" "$BG_CPUS"
            fi
        done
        # SCHED_IDLE: 后台只有空闲CPU才跑 (iOS 后台饥饿的核心)
        if [ "$BG_IDLE" = "1" ]; then
            f="/dev/cpuctl/$g/cpu.idle"
            if [ -e "$f" ]; then
                save_default "$f"
                wr "$f" "1"
            fi
        fi
        # 后台频率封顶
        if [ -n "$BG_UCLAMP_MAX" ] && [ "$BG_UCLAMP_MAX" != "0" ]; then
            f="/dev/cpuctl/$g/cpu.uclamp.max"
            if [ -e "$f" ]; then
                save_default "$f"
                wr "$f" "$BG_UCLAMP_MAX"
            fi
        fi
        # CPU 权重 (只降不升)
        f="/dev/cpuctl/$g/cpu.shares"
        if [ -e "$f" ]; then
            cur="$(cat "$f" 2>/dev/null)"
            if [ -n "$cur" ] && [ "$cur" -gt "$BG_WEIGHT_V1" ] 2>/dev/null; then
                save_default "$f"
                wr "$f" "$BG_WEIGHT_V1"
            fi
        fi
        f="/dev/cpuctl/$g/cpu.weight"
        if [ -e "$f" ]; then
            cur="$(cat "$f" 2>/dev/null)"
            if [ -n "$cur" ] && [ "$cur" -gt "$BG_WEIGHT_V2" ] 2>/dev/null; then
                save_default "$f"
                wr "$f" "$BG_WEIGHT_V2"
            fi
        fi
    done
    # 前台/交互组放开全部核心
    for g in foreground top-app; do
        for f in "/dev/cpuset/$g/cpus" "/dev/cpuctl/$g/cpuset.cpus"; do
            if [ -e "$f" ]; then
                save_default "$f"
                wr "$f" "$TA_CPUS"
            fi
        done
    done
}

# ---------------- 三档 QoS ----------------

UCLAMP_FILE=""

init_boost_nodes() {
    BOOST_NODE_LIST=""
    if [ -e /proc/sys/kernel/sched_boost ] && [ "$TOUCH_SCHED_BOOST" != "0" ]; then
        BOOST_NODE_LIST="$BOOST_NODE_LIST /proc/sys/kernel/sched_boost"
    fi
    UCLAMP_FILE=""
    for f in /dev/cpuctl/top-app/cpu.uclamp.min; do
        [ -e "$f" ] && UCLAMP_FILE="$f"
    done
    if [ -n "$UCLAMP_FILE" ] && [ "$TOUCH_UCLAMP" != "0" -o "$SCREEN_UCLAMP" != "0" ]; then
        BOOST_NODE_LIST="$BOOST_NODE_LIST $UCLAMP_FILE"
    fi
    if [ -n "$TOUCH_MIN_GRAN" ] && [ "$TOUCH_MIN_GRAN" != "0" ] && [ -e /proc/sys/kernel/sched_min_granularity_ns ]; then
        BOOST_NODE_LIST="$BOOST_NODE_LIST /proc/sys/kernel/sched_min_granularity_ns"
    fi
    if [ -n "$TOUCH_WAKEUP_GRAN" ] && [ "$TOUCH_WAKEUP_GRAN" != "0" ] && [ -e /proc/sys/kernel/sched_wakeup_granularity_ns ]; then
        BOOST_NODE_LIST="$BOOST_NODE_LIST /proc/sys/kernel/sched_wakeup_granularity_ns"
    fi
    if [ -n "$TOUCH_SCHED_LATENCY" ] && [ "$TOUCH_SCHED_LATENCY" != "0" ] && [ -e /proc/sys/kernel/sched_latency_ns ]; then
        BOOST_NODE_LIST="$BOOST_NODE_LIST /proc/sys/kernel/sched_latency_ns"
    fi
}

# 应用三档: touch / screen / off
#  touch  : uclamp=TOUCH_UCLAMP + sched_boost/粒度节点(如有)
#  screen : uclamp=SCREEN_UCLAMP, 其余恢复
#  off    : 全部恢复原值
apply_tier() {
    tier="$1"
    quiet="$2"
    desc=""
    for n in $BOOST_NODE_LIST; do
        save_default "$n"
        case "$n" in
            *uclamp.min)
                case "$tier" in
                    touch)  v="$TOUCH_UCLAMP" ;;
                    screen) v="$SCREEN_UCLAMP" ;;
                    *)      v="" ;;
                esac
                ;;
            *)
                case "$tier" in
                    touch)  v="$(node_value "$n")" ;;
                    *)      v="" ;;
                esac
                ;;
        esac
        if [ -n "$v" ] && [ "$v" != "0" ]; then
            wr "$n" "$v"
        else
            restore_one "$n"
        fi
        case "$n" in
            *uclamp.min)                  d="uclamp=$v" ;;
            */sched_boost)                d="sched_boost=$v" ;;
            *sched_min_granularity_ns)    d="min_gran=$v" ;;
            *sched_wakeup_granularity_ns) d="wake_gran=$v" ;;
            *sched_latency_ns)            d="latency=$v" ;;
            *)                            d="" ;;
        esac
        [ -n "$d" ] && desc="$desc $d"
    done
    if [ "$quiet" != "quiet" ]; then
        if [ -n "$desc" ]; then
            log "[$tier]${desc}"
        elif [ -n "$BOOST_NODE_LIST" ]; then
            log "[$tier] 恢复默认调度参数"
        else
            log "[$tier] 本内核无可用交互QoS节点"
        fi
    fi
}

node_value() {
    case "$1" in
        */sched_boost)                echo "$TOUCH_SCHED_BOOST" ;;
        *uclamp.min)                  echo "$TOUCH_UCLAMP" ;;
        *sched_min_granularity_ns)    echo "$TOUCH_MIN_GRAN" ;;
        *sched_wakeup_granularity_ns) echo "$TOUCH_WAKEUP_GRAN" ;;
        *sched_latency_ns)            echo "$TOUCH_SCHED_LATENCY" ;;
    esac
}

# ---------------- 主逻辑 ----------------

main() {
    echo $$ > "$PID_FILE"
    log "===== iOS-Style Scheduler v1.1.1 启动 (pid $$) ====="

    detect_topology
    [ -n "$BG_CPUS" ] || BG_CPUS="$LITTLE_CPUS"
    [ -n "$TA_CPUS" ] || TA_CPUS="$ALL_CPUS"
    log "CPU拓扑: 全部=$ALL_CPUS 小核=$LITTLE_CPUS | 前台=$TA_CPUS 后台组=$BG_GROUPS -> $BG_CPUS"

    # 先还原上一版/上次运行可能留下的全部修改, 再按当前配置应用
    restore_all

    # 亮灭屏节点
    detect_screen_node
    if [ -n "$SCREEN_NODE" ]; then
        log "亮灭屏节点: $SCREEN_NODE (当前: $(cat "$SCREEN_NODE" 2>/dev/null))"
    else
        log "未找到背光节点, 亮屏档将始终生效"
    fi

    # 初始化 QoS 节点清单
    init_boost_nodes
    log "QoS节点:$BOOST_NODE_LIST"
    if [ -n "$UCLAMP_FILE" ]; then
        log "uclamp节点: $UCLAMP_FILE (当前: $(cat "$UCLAMP_FILE" 2>/dev/null))"
    fi

    # 后台持久策略立即生效
    apply_persistent
    log "后台策略已应用: $BG_GROUPS -> 小核$BG_CPUS + SCHED_IDLE=$BG_IDLE + uclamp.max=$BG_UCLAMP_MAX + 权重压制"

    # 开机默认触摸档(亮屏交互场景), 由状态机自然降档
    apply_tier touch
    state="touch"

    # 检测触控输入设备(最多 10 次 x 30 秒)
    TS=""
    tries=0
    while [ -z "$TS" ]; do
        TS="$(find_ts_valid)"
        [ -n "$TS" ] && break
        tries=$((tries + 1))
        if [ "$tries" -ge 10 ]; then
            log "多次未检测到触控输入设备, 进入常开模式(保持触摸档)"
            break
        fi
        log "未检测到触控输入设备, 30 秒后重试 ($tries/10)"
        sleep 30
        apply_persistent
    done
    if [ -n "$TS" ]; then
        log "触控设备: $TS ('$(ts_name "$TS")') | idle=${IDLE_TIMEOUT}s 亮屏档=$SCREEN_UCLAMP 触摸档=$TOUCH_UCLAMP"
    fi

    cnt=0
    last_persist="$(date +%s)"
    while :; do
        # 每 60 秒补写后台持久策略(防系统改回)
        now="$(date +%s)"
        if [ $((now - last_persist)) -ge 60 ]; then
            apply_persistent
            last_persist="$now"
        fi

        # 常开模式(未检测到输入设备 / 无 timeout): 保持触摸档 + 定期补写
        if [ -z "$TS" ] || [ -z "$TO" ]; then
            sleep 60
            if [ -z "$TS" ] && [ -n "$TO" ]; then
                NEWTS="$(find_ts_valid)"
                if [ -n "$NEWTS" ]; then
                    TS="$NEWTS"
                    log "输入设备检测成功: $TS, 切回动态模式"
                    continue
                fi
            fi
            apply_tier touch quiet
            continue
        fi

        if [ "$state" = "off" ]; then
            # 息屏档: 无限阻塞等触摸, 零开销; 一摸即升触摸档
            getevent -c 1 "$TS" > /dev/null 2>&1
            rc2=$?
            if [ "$rc2" != "0" ]; then
                sleep 5
                TS="$(find_ts_valid)"
                [ -z "$TS" ] && log "触控设备读取异常, 转入常开模式"
            fi
            apply_tier touch
            state="touch"
            cnt=0
            continue
        fi

        # 触摸档/亮屏档: 超时等待触摸事件
        wait="$SCREEN_POLL"
        [ "$state" = "touch" ] && wait="$IDLE_TIMEOUT"
        "$TO" "$wait" getevent -c 1 "$TS" > /dev/null 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            # 有触摸 -> 触摸档
            cnt=$((cnt + 1))
            if [ "$state" != "touch" ]; then
                apply_tier touch
                state="touch"
                cnt=0
            elif [ $((cnt % 240)) -eq 0 ]; then
                apply_tier touch quiet
            fi
            continue
        elif [ "$rc" = "124" ]; then
            # 超时无触摸: 依亮灭屏降档
            if [ "$state" = "touch" ]; then
                screen_on
                ss=$?
                if [ "$ss" = "1" ]; then
                    apply_tier off
                    state="off"
                    log "已息屏 -> 进入息屏档(恢复默认, 零开销待命)"
                else
                    apply_tier screen
                    state="screen"
                fi
            else
                # 亮屏档: 轮询检查息屏
                screen_on
                ss=$?
                if [ "$ss" = "1" ]; then
                    apply_tier off
                    state="off"
                    log "已息屏 -> 进入息屏档(恢复默认, 零开销待命)"
                fi
            fi
        else
            log "getevent 异常 (rc=$rc), 5 秒后重试"
            sleep 5
            TS="$(find_ts_valid)"
            [ -z "$TS" ] && log "触控设备读取异常, 转入常开模式"
        fi
    done
}

main
