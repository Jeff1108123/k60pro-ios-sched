#!/system/bin/sh
# KernelSU 模块卡片上的"执行"按钮: 查看当前状态

DATA_DIR="/data/adb/ios_sched"

echo "--- 交互 QoS (触摸时生效) ---"
if [ -e /proc/sys/kernel/sched_boost ]; then
    echo "sched_boost = $(cat /proc/sys/kernel/sched_boost 2>/dev/null)  (0=默认 1=保守 2=激进)"
else
    echo "sched_boost: 节点不存在"
fi
for f in /dev/cpuctl/top-app/cpu.uclamp.min; do
    [ -e "$f" ] && echo "top-app uclamp.min = $(cat "$f" 2>/dev/null)%"
done

echo "--- 后台 QoS ---"
for g in background system-background restricted; do
    if [ -e "/dev/cpuset/$g/cpus" ]; then
        echo "cpuset/$g = $(cat /dev/cpuset/$g/cpus 2>/dev/null)"
    elif [ -e "/dev/cpuctl/$g/cpuset.cpus" ]; then
        echo "cpuset/$g (v2) = $(cat /dev/cpuctl/$g/cpuset.cpus 2>/dev/null)"
    fi
done
for g in background system-background; do
    if [ -e "/dev/cpuctl/$g/cpu.shares" ]; then
        echo "cpuctl/$g shares = $(cat /dev/cpuctl/$g/cpu.shares 2>/dev/null)"
    elif [ -e "/dev/cpuctl/$g/cpu.weight" ]; then
        echo "cpuctl/$g weight = $(cat /dev/cpuctl/$g/cpu.weight 2>/dev/null)"
    fi
done

echo "--- 守护进程 ---"
PID="$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)"
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    echo "运行中 (pid $PID)"
else
    echo "未运行"
fi

echo "--- 最近日志 ---"
tail -n 12 "$DATA_DIR/log.txt" 2>/dev/null
