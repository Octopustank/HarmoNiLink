import { ble, connection } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'HarmoNiLink-BleScanner';

export interface DiscoveredCamera {
  deviceId: string; deviceName: string; rssi: number;
  hasManufacturerData: boolean; isConnectable: boolean;
  /** Nikon camera — recognized by the 0xDE00 service UUID in the BLE
   *  advertisement (reliable, protocol-level). Name heuristics are only used
   *  to dedupe the classic-BT echo of an already-listed camera. */
  isNikon: boolean;
}

// Nikon naming heuristics for broadcast names: Z-series (Z_6_2_...) and
// D-series with 3-4 digit model numbers (D5600_..., D7500_..., D850_...).
// Deliberately narrower than the UUID check — e.g. D61W_... must NOT match
// (observed as a non-Nikon classic device).
function isNikonName(name: string): boolean {
  return /^(Z_|D\d{3,4}_)/.test(name) || name.toUpperCase().includes('NIKON');
}
export type ScanListener = (cameras: DiscoveredCamera[]) => void;

/**
 * Runs three scan channels in parallel: classic BT discovery, the new
 * BleScanner API ('BLEDeviceFind' with ScanReport), and the old ble.on API.
 * Nikon cameras are identified by the 0xDE00 service UUID in the advertisement;
 * the new-API channel reports it via ScanResult.serviceUuids.
 */
export class BleScanner {
  private scanListener: ScanListener | null = null;
  private discoveredCameras: Map<string, DiscoveredCamera> = new Map();
  private isScanning: boolean = false;
  /** New BleScanner API instance (ScanReport-based 'BLEDeviceFind'). */
  private bleScanner: ble.BleScanner | null = null;

  startScan(listener: ScanListener): void {
    hilog.info(0x0001, TAG, `=== startScan() ===`);
    this.scanListener = listener;
    this.discoveredCameras.clear();
    this.isScanning = true;

    // Self-test: check Bluetooth state
    this.selfTest();

    // All three APIs in parallel
    this.tryClassicDiscovery();
    this.tryNewBleApi();
    this.tryOldBleApi();
  }

  private selfTest(): void {
    hilog.info(0x0001, TAG, `--- SELF-TEST ---`);
    try {
      const wasDiscovering = connection.isBluetoothDiscovering();
      hilog.info(0x0001, TAG, `  isBluetoothDiscovering: ${wasDiscovering}`);
    } catch (e) {
      hilog.info(0x0001, TAG, `  isBluetoothDiscovering threw: ${JSON.stringify(e)}`);
    }
    hilog.info(0x0001, TAG, `--- SELF-TEST DONE ---`);
  }

  private tryClassicDiscovery(): void {
    hilog.info(0x0001, TAG, `[CLASSIC] starting...`);
    try {
      connection.on('bluetoothDeviceFind', (data: Object) => {
        const arr = data as string[];
        hilog.info(0x0001, TAG, `[CLASSIC v17] FIRED! ${arr.length} devices: [${arr.join(', ')}]`);
        for (let i = 0; i < arr.length; i++) {
          const cId = arr[i];
          this.add(cId, `BT-device-${i}`, 0, false);
        }
      });

      connection.on('discoveryResult', (data: Object) => {
        const arr = data as Object[];
        hilog.info(0x0001, TAG, `[CLASSIC v18] FIRED! ${arr.length} results`);
        for (let i = 0; i < arr.length; i++) {
          const d = arr[i] as Record<string, Object>;
          const cName = (d['deviceName'] as string) ?? `BT-${i}`;
          this.add(
            (d['deviceId'] as string) ?? '',
            cName,
            (d['rssi'] as number) ?? 0,
            false
          );
        }
      });

      const wasDiscovering = connection.isBluetoothDiscovering();
      hilog.info(0x0001, TAG, `[CLASSIC] wasDiscovering=${wasDiscovering}`);

      if (!wasDiscovering) {
        connection.startBluetoothDiscovery();
        hilog.info(0x0001, TAG, `[CLASSIC] startBluetoothDiscovery() called`);
      }

      // Check after 1 second if discovery actually started
      setTimeout(() => {
        const nowDiscovering = connection.isBluetoothDiscovering();
        hilog.info(0x0001, TAG, `[CLASSIC] after 1s: isDiscovering=${nowDiscovering}`);
        if (!nowDiscovering) {
          hilog.error(0x0001, TAG, `[CLASSIC] DISCOVERY DID NOT START!`);
        }
      }, 1000);

    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[CLASSIC] FAILED: ${e.code} ${e.message}`);
    }
  }

  private tryNewBleApi(): void {
    try {
      this.bleScanner = ble.createBleScanner();
      this.bleScanner.on('BLEDeviceFind', (report: Object) => {
        // NEW API ScanReport structure: {reportType, scanResult: Array<ScanResult>}.
        // reportType: 1 = ON_FOUND, 2 = ON_LOST, 3 = ON_BATCH. We only consume
        // ON_FOUND (and the defensive absent case). ON_BATCH(3) is also dropped,
        // but startScan() below runs in non-batch mode (no reportMode set), so
        // it never occurs in practice — if batch mode is ever enabled, handle it.
        const r = report as Record<string, Object>;
        const reportType = (r['reportType'] as number) ?? -1;
        if (reportType !== -1 && reportType !== 1) {
          return;
        }
        const inner = r['scanResult'];
        if (inner) {
          const arr = inner as Object[];
          for (let i = 0; i < arr.length; i++) {
            const sr = arr[i] as Record<string, Object>;
            const id = (sr['deviceId'] as string) ?? '';
            const name = (sr['deviceName'] as string) ?? '';
            const rssi = (sr['rssi'] as number) ?? 0;
            // Service UUIDs from the advertisement — Nikon cameras advertise
            // 0xDE00; mirror the old-API filter.
            const svcs = (sr['serviceUuids'] as string[] ?? []) as string[];
            const svcHit = svcs.some((u: string) => u.toUpperCase().includes('DE00'));
            hilog.info(0x0001, TAG,
              `[NEW BLE] result[${i}]: id=${id} name='${name}' rssi=${rssi} svcUuids=[${svcs.join(',')}] nikon=${svcHit}`);
            this.add(id, name, rssi, svcHit);
          }
        } else {
          hilog.info(0x0001, TAG, `[NEW BLE] no scanResult in report, keys=[${Object.keys(r).join(',')}]`);
        }
      });
      const opts: ble.ScanOptions = {
        interval: 100, dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      };
      this.bleScanner.startScan(null, opts);
      hilog.info(0x0001, TAG, `[NEW BLE] startScan(null) OK`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[NEW BLE] FAILED: ${e.code} ${e.message}`);
    }
  }

  private tryOldBleApi(): void {
    try {
      ble.on('BLEDeviceFind', (results: Object) => {
        const arr = results as Object[];
        hilog.info(0x0001, TAG,
          `[OLD BLE] FIRED! ${arr.length} results`);
        for (let i = 0; i < arr.length; i++) {
          const r = arr[i] as Record<string, Object>;
          const id = (r['deviceId'] as string) ?? '';
          const name = (r['deviceName'] as string) ?? '';
          const rssi = (r['rssi'] as number) ?? 0;
          // Service UUIDs from the advertisement — Nikon cameras advertise
          // 0xDE00; logged for verification of the filter approach.
          const svcs = (r['serviceUuids'] as string[] ?? []) as string[];
          const svcHit = svcs.some((u: string) => u.toUpperCase().includes('DE00'));
          if (!id || !name) {
            const data = r['data'];
            hilog.info(0x0001, TAG,
              `[OLD BLE] result[${i}] keys=[${Object.keys(r).join(',')}] dataLen=${data ? (data as ArrayBuffer).byteLength : 0} svcUuids=[${svcs.join(',')}]`);
          } else {
            hilog.info(0x0001, TAG,
              `[OLD BLE] result[${i}]: id=${id} name='${name}' rssi=${rssi} svcUuids=[${svcs.join(',')}] nikon=${svcHit || isNikonName(name)}`);
          }
          this.add(id, name, rssi, svcHit);
        }
      });
      const opts: ble.ScanOptions = {
        interval: 100, dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      };
      ble.startBLEScan(null, opts);
      hilog.info(0x0001, TAG, `[OLD BLE] startBLEScan(null) OK`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[OLD BLE] FAILED: ${e.code} ${e.message}`);
    }
  }

  stopScan(): void {
    this.isScanning = false;
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    try { connection.off('bluetoothDeviceFind'); } catch (e) {}
    try { connection.off('discoveryResult'); } catch (e) {}
    try { this.bleScanner?.stopScan(); this.bleScanner?.off('BLEDeviceFind'); } catch (e) {}
    this.bleScanner = null;
    try { ble.stopBLEScan(); ble.off('BLEDeviceFind'); } catch (e) {}
  }

  private add(deviceId: string, deviceName: string, rssi: number, isNikonByUuid: boolean): void {
    if (!deviceId || !this.isScanning) return;
    const existing = this.discoveredCameras.get(deviceId);
    if (existing) {
      // UUID evidence can arrive after a same-device entry was added by another
      // API channel without it (e.g. classic BT, or an earlier new-API report
      // that predates the service-UUID parse). Upgrade in place so the UI can
      // regroup the camera into "尼康相机" immediately.
      if (isNikonByUuid && !existing.isNikon) {
        existing.isNikon = true;
        existing.rssi = rssi;
        if (this.scanListener) {
          this.scanListener(Array.from(this.discoveredCameras.values()));
        }
      }
      return;
    }
    // Virtual-MAC mismatch detection: the same broadcast name arriving under a
    // DIFFERENT deviceId usually means one API channel reports a virtual MAC and
    // another the real one (or a rotated virtual address). Log it so a
    // "same camera twice" symptom is debuggable instead of silent.
    for (const c of this.discoveredCameras.values()) {
      if (c.deviceId !== deviceId && c.deviceName === deviceName) {
        hilog.warn(0x0001, TAG,
          `[VIRTUAL-MAC?] name='${deviceName}' seen as ${c.deviceId} AND ${deviceId}`);
      }
    }
    // Classic-BT echo of an already-listed camera (same broadcast name, no
    // UUID info) — drop it so each camera appears exactly once.
    if (!isNikonByUuid && isNikonName(deviceName)) {
      for (const c of this.discoveredCameras.values()) {
        if (c.isNikon && c.deviceName === deviceName) return;
      }
    }
    hilog.info(0x0001, TAG, `[ADD] id=${deviceId} name='${deviceName}' rssi=${rssi} nikon=${isNikonByUuid}`);
    this.discoveredCameras.set(deviceId, {
      deviceId, deviceName: deviceName || deviceId, rssi,
      hasManufacturerData: false, isConnectable: false, isNikon: isNikonByUuid,
    });
    if (this.scanListener) {
      this.scanListener(Array.from(this.discoveredCameras.values()));
    }
  }
}
