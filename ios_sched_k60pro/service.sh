#!/system/bin/sh
# =============================================================
# 开机启动: 拉起 iOS-Style Scheduler 守护进程
# =============================================================

MODDIR="${0%/*}"
DATA_DIR="/data/adb/ios_sched"

export PATH="/system/bin:/system/xbin:$PATH"

mkdir -p "$DATA_DIR"

# 停止旧守护进程(升级/重装场景)
if [ -f "$DATA_DIR/daemon.pid" ]; then
    kill "$(cat "$DATA_DIR/daemon.pid")" 2>/dev/null
fi
pkill -f "ios_sched_k60pro/daemon.sh" 2>/dev/null
sleep 1

# 等待系统启动完成(最多 90 秒)
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 90 ]; do
    sleep 1
    i=$((i + 1))
done

# 后台启动守护进程
nohup sh "$MODDIR/daemon.sh" >/dev/null 2>&1 &
