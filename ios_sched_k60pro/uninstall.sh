#!/system/bin/sh
# 卸载: 停止守护进程, 还原所有节点原值, 清理数据目录

DATA_DIR="/data/adb/ios_sched"

if [ -f "$DATA_DIR/daemon.pid" ]; then
    kill "$(cat "$DATA_DIR/daemon.pid")" 2>/dev/null
fi
pkill -f "ios_sched_k60pro/daemon.sh" 2>/dev/null

# 还原所有被修改节点的原始值
if [ -f "$DATA_DIR/defaults" ]; then
    while IFS='|' read -r n v; do
        [ -n "$n" ] && [ -e "$n" ] && echo "$v" > "$n" 2>/dev/null
    done < "$DATA_DIR/defaults"
fi

rm -rf "$DATA_DIR"
