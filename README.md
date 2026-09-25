# K60 Pro iOS风格调度增强 (KernelSU 模块)

红米 K60 Pro (socrates) 专用 KernelSU 模块：仿照 iOS 的 QoS 分层调度，建议与 noactive（墓碑冻结）搭配使用。

## 功能

- **三档 QoS 状态机**：触摸档（top-app uclamp=60，跟手）→ 亮屏档（uclamp=25，看视频/阅读不掉 QoS）→ 息屏档（恢复原值，零开销待命）
- **后台饥饿策略**：`cpu.idle=1`（SCHED_IDLE，后台只在空闲 CPU 上运行）+ `uclamp.max` 频率封顶 + cpuset 锁小核 + CPU 权重压制
- 所有被修改节点的原值自动存档，卸载自动还原
- 触摸/息屏自动检测；`goodix_ts` 输入设备精确识别（排除 uinput 虚拟设备）

## 安装 / 在线更新

KernelSU 管理器 → 模块 → 从存储安装 `ios_sched_k60pro-*.zip`（Release 下载）。

已安装用户在管理器中会自动收到更新提示（模块内置 `updateJson`，指向本仓库 `update.json`），点"更新"即可在线升级。

## 配置

`/data/adb/ios_sched/config`，详见模块内 README.md 与 config 注释。

## 发布新版本

维护者流程（一条命令完成打包 + Release + 在线更新索引更新）：

```powershell
.\publish.ps1 -Version v1.2.0 -VersionCode 11200 -Changelog "更新说明"
```

脚本自动完成：版本号写入 module.prop → LF/UTF-8 规范化 → 打 zip → 更新 update.json → 提交推送 → 创建 GitHub Release 上传 zip。

## 目录结构

```
ios_sched_k60pro/   # 模块源文件 (zip 根目录内容)
update.json         # KernelSU 在线更新索引 (由 publish.ps1 生成)
publish.ps1         # 发布脚本
```
