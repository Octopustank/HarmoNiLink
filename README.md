# HarmoNiLink — Nikon Smart GPS for HarmonyOS NEXT

[![License: MulanPSL v2](https://img.shields.io/badge/License-MulanPSL_v2-blue.svg)](./LICENSE)

> Inspired by [hurui200320/nsg](https://github.com/hurui200320/nsg)，
> 基于 [gkoh/furble](https://github.com/gkoh/furble) 逆向的 Nikon BLE 智能设备协议。

HarmoNiLink 让 HarmonyOS 手机/平板替代 SnapBridge，向尼康 Z / D 系列相机**持续分发 GPS 坐标**。连接后全自动运行 — 相机休眠时保持低功耗连接，App 在后台静默传输位置数据。

由于鸿蒙系统在卓易通使用 SnapBridge 存在功能异常（截止作者测试），遂开发此应用代替之

---

## 截图

| 配对 & 扫描 | 连接 & GPS | 连接健康度 |
|:---:|:---:|:---:|
| <img src="pics/pair.png" width="280"/> | <img src="pics/connected.png" width="280"/> | <img src="pics/health.png" width="280"/> |

---

## 特性

### 全自动 GPS 分发
扫描、配对、GPS 传输全流程自动化。首次配对需用户确认系统弹窗，之后所有操作（含休眠唤醒重连）均无需手动介入。

### 智能扫描分组
扫描时通过蓝牙广播中的服务特征（0xDE00）自动识别尼康相机并置顶分组（`Z_6_2_...`、`D5600_...`），手机、耳机、打印机等其他设备收进折叠区——多相机、嘈杂环境一目了然，不再大海捞针。

### 连接状态引导
当相机端正在等待另一台已配对设备时（多台手机配对过同一台相机），App 会自动提示在相机【已配对设备】中切换当前设备，不再无声重试。

### 鸿蒙原生后台保活
基于 `BackgroundMode.BLUETOOTH_INTERACTION` + `LOCATION` 双长时任务，不依赖无声音频等取巧手段。系统级后台调度保证 GPS 持续传输。后台持续下发需将定位权限设为「始终允许」，见[权限](#权限)。

### 相机休眠兼容
尼康相机进入休眠后维持 BLE 低功耗连接，GPS 数据持续写入。若连接意外中断（深度休眠 / 超出距离），自动执行指数退避重连。Z 系列与 D 系列（D5600 等）均已适配——D 系列较慢的连接建立与经典蓝牙配对时序（需 BLE 连接完全释放后才可被发现）自动处理，无需手动干预。

### 多设备可区分
每台安装自动生成唯一配对名称（`HarmoNiLink-XXXX`），写入相机并显示在相机端已配对列表，多台手机同时配对同一台相机时互不混淆；连接页可随时查看本机名称。

### 原生鸿蒙体验
- **HDS 设计套件** — 沉浸光感、模糊标题栏、自适应背景材质
- **亮/暗主题跟随** — 自动跟随系统色彩模式
- **大屏适配** — 折叠屏展开 / 平板全屏铺满，无平行视界空白
- **纯 ArkTS 实现** — Blowfish 加密全程 ArkTS 运算，零原生依赖

---

## 支持的设备

| 平台 | 要求 |
|------|------|
| 手机 / 平板 | HarmonyOS NEXT（运行要求 API 23 / SDK 6.1.0 及以上；构建于 SDK 6.1.1 · API 24） |
| 相机 | 尼康 Z 系列（Z 6II、Z 7II、Z 8、Z 9、Z f 等）与 D 系列（D5600 等） |

> ✅ Z 6II、D5600 真机验证通过；其他型号欢迎测试反馈。

---

## 权限

| 权限 | 用途 | 说明 |
|------|------|------|
| 蓝牙（发现附近设备） | 扫描、配对、连接相机 | 首次扫描时申请 |
| 位置（精确位置） | 向相机下发 GPS 坐标 | 首次扫描时申请，请在弹窗中选择精确位置 |
| 后台定位（始终允许） | 相机休眠 / 应用在后台时持续下发 GPS | **可选**。系统不允许通过弹窗授予，需在系统设置中将定位权限设为「始终允许」；首次授权后会提示一次，可随时跳过（会略微增加耗电） |

后台定位未开启时：连接保持，但应用切到后台后 GPS 停止下发，回到前台自动恢复。

---

## 架构

```
entry/src/main/ets/
├── ble/
│   ├── BleClient.ets                  — GATT 客户端
│   ├── BleScanner.ets                 — BLE 设备扫描
│   └── protocol/
│       ├── NikonPairingEngine.ets      — 4 阶段配对握手
│       ├── BlowfishHasher.ets          — Blowfish hash（纯 ArkTS）
│       ├── GeoPayloadGenerator.ets     — 41 字节 GPS 载荷
│       └── TimePayloadGenerator.ets    — 时间载荷
├── pages/
│   ├── MainPage.ets                   — 标签页容器
│   ├── PairingPage.ets                — 扫描 & 配对
│   └── ConnectionPage.ets             — 连接状态 & 设备管理
├── components/
│   ├── DeviceHealthSheet.ets          — 设备信息 & 连接健康度看板
│   ├── AboutSheet.ets                 — 关于面板
│   └── CommentDialog.ets              — 应用市场评价弹窗
├── service/
│   ├── CameraService.ets              — 多相机连接 Hub（会话/共享扫描/互斥/状态广播）
│   ├── CameraSession.ets              — 单相机会话：连接/握手/重连退避
│   ├── ClassicBonding.ets             — 经典蓝牙绑定协调器
│   ├── GpsDispatcher.ets              — GPS 单时钟分发（TIME/GEO 轮写）
│   ├── BackgroundTaskKeeper.ets       — 长时任务生命周期 & 中断提醒
│   ├── PermissionsGateway.ets         — 按需权限申请
│   ├── SlaHub.ets                     — 连接健康度追踪注册表
│   └── RatingPrompt.ets               — 评分弹窗门槛
├── data/
│   ├── PreferencesRepository.ets      — 已配对设备 & 控制器名称持久化
│   └── SlaTracker.ets                 — 健康度时间轴（2h 环形槽）
└── entryability/
    └── EntryAbility.ets               — 入口 & 生命周期
```

| 层 | 技术 |
|---|---|
| UI | ArkTS / ArkUI · `@kit.UIDesignKit` |
| BLE | `@ohos.bluetooth.ble` · `@ohos.bluetooth.connection` |
| 定位 | `@kit.LocationKit` |
| 后台 | `backgroundTaskManager` — `BLUETOOTH_INTERACTION` · `LOCATION` |
| 构建 | Hvigor 6.0.0 · arm64-v8a |

---

## BLE 协议概要

```
Base UUID: 0000xxxx-3dd4-4255-8d62-6dc7b9bd5561

Service  0xDE00
  ├── 0x2000 (PAIR)  配对握手 — Blowfish 3 阶段 17 字节消息
  ├── 0x2002 (ID)    写入控制器名称（HarmoNiLink-XXXX）— 32 字节 ASCII
  ├── 0x2007 (GEO)   写入 41 字节 GPS 载荷
  └── 0x2008 (NOT1)  通知通道 — 相机状态
```

- **加密**：Blowfish/ECB/NoPadding · 密钥 `FF FF AA 55 11 22 33 00`
- **Hash**：自定义 CBC-MAC（Big-Endian 32-bit word 级）
- **GEO 载荷**：WGS-84 · 经纬度/海拔/卫星数/UTC · 41 字节

---

## 构建

环境：[DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 或 [Command Line Tools for HMOS](https://developer.huawei.com/consumer/en/download/command-line-tools-for-hmos)，SDK 6.1.1（API 24）。构建产物兼容 API 23 及以上设备。

```bash
make hap     # 开发调试 — 未签名 .hap
make app     # 未签名 .app
make build   # 两个都构建

make sign    # 构建 + 双层签名 → .hap + .app（需先 cp .env.example .env 并填密码）
make clean   # 清理构建产物
```

产物 (`make sign` 后)：
- `build/outputs/default/HarmoNiLink-default-signed.hap` — 签名模块包
- `build/outputs/default/HarmoNiLink-default-signed.app` — 签名应用包

---

## 灵感来源

本项目为独立重实现

### [nsg](https://github.com/hurui200320/nsg)
由 **skyblond** 开发的 Android Kotlin 参考实现（AGPL-3.0）。本项目的协议流程、配对握手、载荷格式均基于其公开的协议分析重新实现。

### [furble](https://github.com/gkoh/furble)
由 **Guo-Rong Koh** 开发的 ESP32 多品牌相机遥控器（MIT）。最早逆向 Nikon BLE 智能设备协议并公开文档。

---

## 许可证

[Mulan Permissive Software License v2](./LICENSE) © 2026 octopustank
