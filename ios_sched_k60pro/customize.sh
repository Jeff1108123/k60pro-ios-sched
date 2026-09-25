#!/system/bin/sh
# =============================================================
# K60 Pro iOS风格调度增强 v1.1.1 - 安装脚本 (KernelSU)
# 建议: 与 noactive(墓碑冻结) 模块搭配使用
# =============================================================

SKIPUNZIP=0

ui_print "======================================"
ui_print " K60 Pro iOS风格调度增强 v1.1.1"
ui_print "======================================"

DEV="$(getprop ro.product.device)"
ui_print "- 当前设备: $DEV ($(getprop ro.product.marketname))"

case "$DEV" in
    sundown|socrates)
        ui_print "- 设备匹配: 红米 K60 Pro"
        ;;
    *)
        ui_print "! 注意: 本模块针对 红米K60 Pro (socrates) 制作"
        ui_print "! 当前设备不匹配, 仍将继续安装"
        ;;
esac

# 持久配置目录(旧配置自动迁移)
mkdir -p /data/adb/ios_sched
if [ -f /data/adb/ios_sched/config ]; then
    if grep -q "SCREEN_UCLAMP" /data/adb/ios_sched/config 2>/dev/null; then
        ui_print "- 已保留原配置: /data/adb/ios_sched/config"
    else
        mv /data/adb/ios_sched/config /data/adb/ios_sched/config.old.bak
        cp "$MODPATH/config" /data/adb/ios_sched/config
        ui_print "- 旧配置已备份为 config.old.bak, 已生成新配置"
    fi
else
    cp "$MODPATH/config" /data/adb/ios_sched/config
    ui_print "- 已生成默认配置: /data/adb/ios_sched/config"
fi

# 打印当前可用的调度接口
ui_print "- 调度接口探测:"
[ -e /proc/sys/kernel/sched_boost ] && ui_print "    sched_boost: 有" || ui_print "    sched_boost: 无(触摸boost跳过)"
[ -e /proc/sys/kernel/sched_min_granularity_ns ] && ui_print "    sched_min_granularity_ns: 有" || ui_print "    调度粒度节点: 无(跳过)"
[ -e /dev/cpuctl/top-app/cpu.uclamp.min ] && ui_print "    top-app cpu.uclamp.min: 有" || ui_print "    top-app cpu.uclamp.min: 无"

ui_print "- cpuset 组:"
for g in top-app foreground background system-background restricted; do
    if [ -e "/dev/cpuset/$g/cpus" ]; then
        ui_print "    $g = $(cat /dev/cpuset/$g/cpus 2>/dev/null)"
    elif [ -e "/dev/cpuctl/$g/cpuset.cpus" ]; then
        ui_print "    $g (v2) = $(cat /dev/cpuctl/$g/cpuset.cpus 2>/dev/null)"
    fi
done

ui_print "- 安装完成, 重启后生效"
