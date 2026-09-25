# K60 Pro iOS风格调度增强 (KernelSU 模块)

红米 K60 Pro (socrates) 专用：仿照 iOS 的 QoS 分层调度，建议与 **noactive**（墓碑冻结）搭配使用，构成完整的类 iOS 体验。

## iOS 调度 → 本模块的映射

| iOS 机制 | 本模块实现 |
|---|---|
| User Interactive QoS（交互最高优先级） | 触摸时 top-app 组 `cpu.uclamp.min` 提升（前台线程保底 60% 运行能力）；若内核有 `sched_boost`/调度粒度节点则一并使用（本机 Niko GKI 内核无这些节点，自动跳过，uclamp 是主力） |
| Background QoS 限制在效率核 | `background` 组 cpuset **锁定小核**（SM8550 即 CPU0-2）+ CPU 权重压制（只降不升）。`system-background`/`restricted` 由系统管理**默认不动**：前者含音频等低延迟服务，后者被 HyperOS 游戏加速使用，锁小核会导致游戏掉帧 |
| 前台独占性能 | `foreground` / `top-app` cpuset 放开全部核心 |
| 无交互时降低活跃度 | 无触摸 15 秒后，boost 参数**自动恢复原值** |
| 墓碑机制 | 由已安装的 noactive 模块负责（本模块不管冻结） |

## 工作方式

守护进程监听触控输入设备（与触控采样率模块同款检测逻辑，已验证：排除 `uinput-goodix` 虚拟设备、精确匹配 `goodix_ts`）：

```
触摸中    -> do_boost (sched_boost/uclamp/低延迟粒度), 每240事件补写
无触摸15s -> do_relax (恢复原值, 省电)
再触摸    -> 立即 do_boost
每60秒    -> 后台策略补写 (cpuset锁小核+降权, 防系统改回)
```

**安全机制**：所有被修改节点（sched_boost、uclamp、粒度、cpuset、权重）的原始值在首次写入前自动存档到 `/data/adb/ios_sched/defaults`；空闲恢复、卸载自动全量还原。CPU 权重只会降不会升（若系统本来就比你设的更严格则不动）。

## 安装

1. KernelSU 管理器 → 从存储安装 → `ios_sched_k60pro-v1.0.0.zip`
2. 重启
3. 模块卡片"执行"按钮查看当前状态（sched_boost、后台 cpuset、日志）

## 验证

```bash
# 触摸屏幕时: sched_boost 应为 2; 停手 15 秒后应恢复 0
adb shell su -c "cat /proc/sys/kernel/sched_boost"
adb shell su -c "cat /dev/cpuctl/top-app/cpu.uclamp.min"

# 后台组应锁定在小核 (SM8550: 0-2)
adb shell su -c "cat /dev/cpuset/background/cpus"

# 日志: 应有 [boost]/[relax]/后台策略 交替记录
adb shell su -c "cat /data/adb/ios_sched/log.txt"
```

体感对比方法：重启后先玩 10 分钟游戏/滑动信息流，再进 config 把 `TOUCH_SCHED_BOOST=0` `TOUCH_UCLAMP=0` 重启对比；或者临时停用模块对比。

## 配置 (/data/adb/ios_sched/config)

| 参数 | 默认 | 说明 |
|---|---|---|
| `IDLE_TIMEOUT` | 15 | 无触摸多少秒后恢复默认参数 |
| `TOUCH_SCHED_BOOST` | 2 | 触摸时档位：0关 / 1保守 / 2激进（费电点但最跟手） |
| `TOUCH_UCLAMP` | 60 | 触摸时 top-app 最低运行能力百分比（0=不动） |
| `TOUCH_MIN_GRAN/WAKEUP_GRAN/LATENCY` | 1ms/0.5ms/8ms | 触摸时调度延迟参数（0=不动） |
| `RESTRICT_BG` | 1 | 后台锁小核+降权开关 |
| `BG_WEIGHT_V1/V2` | 400/50 | 后台权重上限（只降不升） |

注意：若为 cgroup v1 环境（无 `cpu.uclamp.min`），uclamp 增强自动跳过，其余照常。小核范围按 `cpu_capacity` 自动探测，无需手填。

## 与触控采样率模块的关系

两个模块独立运行、互不冲突（一个写触控 IC 报点率，一个写内核调度/cgroup），可以同时安装。各自监听触控事件的 evdev 支持多读者。

## 卸载

自动停止守护进程、**还原全部节点原值**、清理配置。

## 注意事项

- `sched_boost=2` 触摸期间会让任务更倾向大核，游戏等重载场景发热会略增——只在有人交互时生效，息屏/闲置自动恢复。
- HyperOS 自己的 perfd/游戏加速也会写这些节点，守护进程通过"触摸补写 + 每60秒后台策略补写"来保持自己的策略；若你在游戏加速里手动开了性能模式，以你的手动设置感受为准。
- 后台锁小核是全局策略：极端情况下后台大量计算的任务会变慢（这正是 iOS 的行为），如个别应用后台同步异常，可把 `RESTRICT_BG` 改 0 关闭。

## 文件结构

```
ios_sched_k60pro/
├── module.prop
├── customize.sh    # 安装(设备检查、接口探测打印)
├── service.sh      # 开机启动守护进程
├── daemon.sh       # 守护进程(拓扑探测/QoS分层/触摸驱动)
├── action.sh       # "执行"按钮: 查看状态
├── uninstall.sh    # 卸载还原
├── config          # 默认配置模板
└── README.md
```
