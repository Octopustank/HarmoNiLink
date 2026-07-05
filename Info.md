> `./nsg` 是参考项目（`https://github.com/hurui200320/nsg`）仓库

# HarmoNikon — nsg (Nikon Smart GPS) 鸿蒙移植调研

---

## 项目目标

将 [hurui200320/nsg](https://github.com/hurui200320/nsg) 移植到 HarmonyOS NEXT，实现鸿蒙手机代替 SnapBridge 向尼康 Z 系列相机分发 GPS 坐标。

---

## 一、nsg 协议本质

### BLE GATT 服务

```
Base UUID: 0000xxxx-3dd4-4255-8d62-6dc7b9bd5561

Service:    0000DE00-...    
  ├── PAIR  0x2000  配对握手（需要用 Blowfish 做 3 阶段 17 字节消息交换）
  ├── ID    0x2002  写入控制器名称（32 字节 ASCII，不足补零）
  ├── GEO   0x2007  写入 41 字节 GPS 载荷
  └── NOT1  0x2008  通知通道（相机发送状态消息）
```

### 配对握手流程

1. **Stage 1**：APP 生成 random timestamp(8B) + random device(4B, LSB=0x01) + random nonce(4B) → 写入 PAIR
2. **Stage 2**：相机回复，APP 用 8 组 salt 验算 hash，匹配则确定 salt
3. **Stage 3**：APP 用确定 salt 重新 hash，生成 device + nonce → 写入 PAIR
4. **Stage 4**：相机回复 serial 后，等待 NOT1 的 `01 00` 表示完成
5. **最后**：写入 ID characteristic

### Blowfish 算法

- **算法**：Blowfish/ECB/NoPadding
- **密钥**：`FF FF AA 55 11 22 33 00`（8 字节）
- **模式**：自定义 CBC-MAC — 每 64-bit 按 big-endian 打包，加密后按 big-endian 拆为 32-bit word
- **Hash 函数**：初始向量 `0x01020304, 0x05060708`，每个块 XOR 后加密，结果作为下一轮输入

### GEO 载荷（41 字节）

| 偏移 | 大小 | 说明 |
|------|------|------|
| 0 | 2 | 固定 `0x007F` LE |
| 2 | 1 | 纬度方向 `'N'`/`'S'` |
| 3 | 4 | 纬度度、分、submin1、submin2 |
| 7 | 1 | 经度方向 `'E'`/`'W'` |
| 8 | 4 | 经度度、分、submin1、submin2 |
| 12 | 1 | 卫星数 (3-12) |
| 13 | 1 | 海拔参考 `'P'`/`'M'` |
| 14 | 2 | 海拔(米) LE |
| 16 | 7 | UTC 时间：年(LE)、月、日、时、分、秒 |
| 23 | 1 | 亚秒 (0-99) |
| 24 | 1 | 有效标志 `0x01` |
| 25 | 6 | `"WGS-84"` |
| 31 | 10 | 填充 `0x00` |

坐标转换：`decimal = degrees + minutes/60 + submin1/6000 + submin2/600000`

---

## 二、HarmonyOS NEXT API 对等映射

### 蓝牙栈

nsg 涉及 **BLE GATT 通信** + **经典蓝牙 bonding** 两个层面。关键调研结论如下。

#### BLE GATT

| Android | HarmonyOS NEXT | 包路径 |
|---------|---------------|--------|
| `BluetoothLeScanner` | `ble.startBLEScan()` | `@kit.ConnectivityKit` → `@ohos.bluetooth.ble` |
| `BluetoothGattCallback` | `BleCentralDevice` + callback | 同上 |
| `connectGatt()` | `createGattClientDevice().connect()` | 同上 |
| `discoverServices()` | 自动发现 | 同上 |
| `setCharacteristicNotification()` | `setNotifyCharacteristic()` | 同上 |
| `writeCharacteristic()` | `writeCharacteristicValue()` | 同上 |
| `requestMtu()` | `setMTU()` | 同上 |

#### 双模蓝牙配对（核心发现）

**直接用 BLE 扫描到的虚拟 MAC 地址调用 `connection.pairDevice()`，鸿蒙系统层会自动处理：**

- RPA（可解析私有地址）轮换问题
- BLE 与经典蓝牙一次性完成双重绑定
- 配对后该虚拟 MAC 地址永久固化，可直接持久化存储用于后续无感重连

```ts
import { ble, connection } from '@kit.ConnectivityKit';

// 扫描到尼康相机
ble.startBLEScan([{ serviceUuid: '0000de00-3dd4-4255-8d62-6dc7b9bd5561' }], {
  interval: 50
});

// 配对（会弹出系统对话框，用户确认即完成双模绑定）
connection.pairDevice(deviceId);
```

**注意**：
- 首次调用 `pairDevice()` 系统强制弹出原生配对确认框 — 无法静默配对（无 `BLUETOOTH_PRIVILEGED` 权限）
- 用户点击确认后，后续所有重连在后台静默完成
- 配对成功后 `bondStateChange` 回调通知

### 后台保活

| 概念 | Android | HarmonyOS NEXT |
|------|---------|---------------|
| 机制 | ForegroundService | ContinuousTask (长时任务) |
| 声明 | `foregroundServiceType="connectedDevice"` | `module.json5` → `backgroundModes` |
| 保活模式 | 前台服务 + 通知 | `BackgroundMode.BLUETOOTH_INTERACTION` + `LOCATION` |

```json5
// module.json5
"requestPermissions": [
  { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" },
  { "name": "ohos.permission.USE_BLUETOOTH" },
  { "name": "ohos.permission.DISCOVER_BLUETOOTH" },
  { "name": "ohos.permission.APPROXIMATELY_LOCATION" },
  { "name": "ohos.permission.LOCATION" }
]
```

```json5
// abilities 配置
"abilities": [{
  "backgroundModes": ["bluetoothInteraction", "location"]
}]
```

```ts
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';

// 启动长时任务
backgroundTaskManager.startBackgroundRunning(
  context,
  backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION,
  wantAgent
);
```

**结论**：`bluetoothInteraction` 是系统级蓝牙外设通信保活模式，不需要无声音频等违规手段。

### Blowfish 加密

| 方面 | 结论 |
|------|------|
| CryptoArchitectureKit | ❌ 不包含 Blowfish（聚焦国密/AES/现代算法） |
| 纯 ArkTS 实现 | ⚠️ 可行但易出错、性能差，不推荐 |
| **推荐方案** | **NAPI (Node-API)** 桥接成熟 C/C++ Blowfish 库 |

```c
// NAPI 模块示例结构
// napi_module/src/blowfish.cpp
// - 引入 OpenSSL 或独立 Blowfish 实现
// - 暴露 Napi::Value Encrypt(const Napi::CallbackInfo& info)
// - 暴露 Napi::Value Decrypt(const Napi::CallbackInfo& info)
```

### GPS 数据源

```ts
import { geoLocationManager } from '@kit.LocationKit';

const pos = await geoLocationManager.getCurrentLocation({
  priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
  timeoutMs: 10000
});
// pos.latitude, pos.longitude, pos.altitude, pos.timestamp
```

---

## 三、已知风险与不确定点

### 需要真机验证

1. **经典蓝牙 bonding timing** — 相机是否在 BLE 握手完成后才暴露经典蓝牙地址，时序是否与 Android 一致
2. **RPA 固化** — pairDevice 后虚拟 MAC 地址是否真的永久固化，相机休眠/固件升级后是否仍然有效
3. **NAPI 模块打包** — NAPI .so 能否正常打包入 HAP，以及 hvigor 的 `.so` 合并规则（参考 harmonyos-dev-gotchas 第 1 条）
4. **MTU 协商** — 尼康相机是否接受 > 23 的 MTU，否则 41 字节 GEO 载荷需分包

### 已知限制

- 首次配对需要用户确认系统弹窗，无法完全静默
- 鸿蒙 BLE 扫描的 `deviceId` 格式与 Android 的 `BluetoothDevice.getAddress()` 可能不同
- `ohos.permission.APPROXIMATELY_LOCATION` 是 `user_grant` 权限，需动态申请并携带 `usedScene`

---

## 四、参考信源

- **[1]** nsg 源码：[hurui200320/nsg](https://github.com/hurui200320/nsg) — README.md, android/impl-plan.md, doc/nikon-z-gps.md
- **[2]** HarmonyOS BLE API：[@ohos.bluetooth.ble](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-bluetooth-ble)
- **[3]** HarmonyOS 蓝牙配对 API：[@ohos.bluetooth.connection](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-bluetooth-connection) — pairDevice, getPairedDevices
- **[4]** HarmonyOS 后台任务：[@kit.BackgroundTasksKit](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-backgroundtaskmanager) — BackgroundMode.BLUETOOTH_INTERACTION
- **[5]** HarmonyOS 加密架构：[@kit.CryptoArchitectureKit](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-cryptoFramework)
- **[6]** HarmonyOS 定位：[@kit.LocationKit](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-geolocationmanager) — geoLocationManager
- **[7]** 经典蓝牙/BLE 双模地址机制：华为开发者论坛 — 双模设备配对与虚拟地址架构指南
- **[8]** NAPI 开发指南：[HarmonyOS NAPI](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/napi)
