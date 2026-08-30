# HarmoNiLink — Nikon Smart GPS for HarmonyOS NEXT

[![License: MulanPSL v2](https://img.shields.io/badge/License-MulanPSL_v2-blue.svg)](./LICENSE)

> Inspired by [hurui200320/nsg](https://github.com/hurui200320/nsg)，
> 基于 [gkoh/furble](https://github.com/gkoh/furble) 逆向的 Nikon BLE 智能设备协议。

HarmoNiLink 让 HarmonyOS 手机/平板替代 SnapBridge，向尼康 Z / D 系列相机**持续分发 GPS 坐标**。连接后全自动运行 — 相机休眠时保持低功耗连接，App 在后台静默传输位置数据。

由于鸿蒙系统在卓易通使用 SnapBridge 存在功能异常（截止作者测试），遂开发此应用代替之

---

## 应用预览

| | |
|:---:|:---:|
| **自动发现，一键配对** | **实时同步 GPS 信息** |
| <img src="pics/promo-1-pairing.png" width="300"/> | <img src="pics/promo-2-gps-sync.png" width="300"/> |
| **持续连接，全天候跟拍** | **位置信息写进照片文件** |
| <img src="pics/promo-3-always-connected.png" width="300"/> | <img src="pics/promo-4-exif.png" width="300"/> |

---

## 核心亮点

### 便捷连接，专注拍摄
首次蓝牙配对成功后，每次打开应用只需轻触连接按钮，GPS 信息便会自动实时下达相机，连接后无需额外操作。

### 快门记录经纬，不止于光影
拍摄时，相机接收的位置信息（可在相机「连接至智能设备」-「位置数据」查看）会写入 RAW / JPG 照片的 EXIF 中。照片导入电脑或手机相册后自带地理坐标，地图模式自动归位。

### 后台稳定运行，持续连接
基于系统原生蓝牙和定位任务机制，应用切到后台仍可稳定传输位置数据（需在系统设置中将定位权限设为「始终允许」），拍摄无干扰。若后台进程被系统中断，回到前台会自动恢复并给出提示。

### 连接健康，一目了然
每一台已配对相机都记录最近 2 小时连接健康度，四级状态直观呈现，正常、偶发断连、定位异常、完全中断一目了然（已配对设备左滑查看，删除设备也在左滑菜单中）。

### 一台手机，多台相机
可同时连接多台尼康相机，每台独立开关、独立管理，一台休眠或断线不影响另一台；多台共享同一份定位数据，互不干扰。

### 适配相机休眠，连接不掉线
相机进入低功耗休眠后，蓝牙连接保持，GPS 持续下达；若意外断开，自动执行重连策略，省心省力。

### 纯净界面设计
遵循 HDS 设计规范，支持沉浸光感、模糊标题栏，自动跟随系统亮/暗主题；点击条目有按压反馈，操作跟手。

---

## 使用指引

1. 相机开启蓝牙配对模式，手机开启蓝牙与定位功能，打开应用后按照页面指引完成相机的蓝牙搜索与配对
2. 在连接页面打开对应相机的连接开关，应用会自动持续向相机下发 GPS 坐标信息。GPS 信息可以在相机「连接至智能设备」-「位置数据(智能设备)」中查看
3. 相机拍摄照片时将自动记录获取到的位置信息到 RAW/JPG 的元数据，便于后期整理分类

---

## 支持的设备

| 平台 | 要求 |
|------|------|
| 手机 / 平板 | HarmonyOS NEXT（运行要求 API 23 / SDK 6.1.0 及以上；构建于 SDK 26.0.0 · API 26） |
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
| 构建 | hvigor-ohos-plugin 6.26.4 · arm64-v8a |

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

环境：[DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 或 [Command Line Tools for HMOS](https://developer.huawei.com/consumer/en/download/command-line-tools-for-hmos)，SDK **26.0.0（API 26）**，hvigor-ohos-plugin 6.26.4。构建产物兼容 API 23（SDK 6.1.0）及以上设备（compatibleSdkVersion 6.1.0(23)）。

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

> 需要使用 **API 24 工具链**构建？检出到 v2.4.2 标签即可：`git checkout v2.4.2`（最后一个以 SDK 6.1.1 · API 24 构建的版本，compatibleSdkVersion 相同）。

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
